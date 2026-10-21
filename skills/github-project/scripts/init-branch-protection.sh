#!/usr/bin/env bash
# init-branch-protection.sh
# Apply Netresearch standard branch protection to a GitHub repository.
#
# REQUIRED step after `gh repo create` + initial push, BEFORE opening the
# first PR. (The default branch ref must exist — push your initial commit
# first; this script exits 4 on empty repos.) The structural enforcement
# applied here (required_conversation_resolution, plus one required approval
# unless --solo) is what makes the unresolved-threads workflow rule actually
# safe — operator
# discipline alone has demonstrably failed (see
# netresearch/snipe-it-docker-compose-stack#17).
#
# Usage:
#   bash init-branch-protection.sh <owner>/<repo>
#       Apply baseline protection (no required status checks yet — for new
#       repos with no CI history). Idempotent: a second run reports
#       "already compliant" and exits 0 if no drift, or exits 1 with a
#       per-field diff if drift is present on opinionated fields. The
#       script never auto-corrects drift — it refuses to clobber explicit
#       admin choices.
#
#   bash init-branch-protection.sh <owner>/<repo> --from-current-checks
#       Follow-up after the first successful CI run. Reads check-run names
#       from /commits/{default_branch}/check-runs. If the protection already
#       has a required_status_checks block, PATCHes it via the
#       .../protection/required_status_checks subresource (other fields
#       untouched). If it has none — the state the baseline leaves behind —
#       that subresource answers 404 "Required status checks not enabled"
#       and cannot create the block, so the script re-PUTs the whole
#       protection built from the current GET: every existing field
#       (incl. bypass_pull_request_allowances, dismissal_restrictions,
#       restrictions) is carried over, required_status_checks is added,
#       required_signatures is left out (separate endpoint, not a PUT field).
#       strict ("require branches to be up to date") is sent as true, or as
#       false when a merge_queue rule is in effect on the default branch:
#       the queue replaces the author-side update strict would force.
#
#   bash init-branch-protection.sh <owner>/<repo> --solo
#       Same as the first form, but with required_approving_review_count 0,
#       for a single-maintainer repository without a pr-quality.yml
#       auto-approve workflow. GitHub does not let an author approve their
#       own pull request, so one required approval would make every merge
#       need an admin bypass there. Conversation resolution, the force-push
#       and deletion bans and the later required status checks still gate
#       the merge. Drift is checked against the same 0.
#
#   bash init-branch-protection.sh <owner>/<repo> --merge-queue
#       Adds the Netresearch merge queue to the default branch. Run it after
#       the baseline and after --from-current-checks. Reads everything first:
#       the repository, the rules in effect on the default branch
#       (GET /rules/branches/{branch}, which includes org rulesets) and the
#       classic protection. It refuses, without writing anything, when:
#         - merge commits are disabled (the queue merges with MERGE),
#         - a required context is one that apps post only against the pull
#           request and never on a merge_group ref (CodeQL, Opengrep OSS,
#           betterleaks, zizmor, SonarCloud Code Analysis): every queue
#           entry would time out (exit 6),
#         - a ruleset requires branches to be up to date
#           (strict_required_status_checks_policy: true),
#         - a merge_queue rule exists with other parameters (drift, exit 1).
#       Otherwise it creates a dedicated repository ruleset "merge-queue"
#       targeting ~DEFAULT_BRANCH with only the merge_queue rule (it never
#       rewrites an existing ruleset), reads it back, and sets the classic
#       strict flag ("require branches to be up to date") to false, because
#       the queue replaces the author-side update it forces. A queue that
#       already exists with the standard parameters is left alone.
#       The merge_queue rule exists only in repository rulesets; an org
#       ruleset rejects it and classic protection has no toggle for it.
#       Every workflow that produces a required context needs `merge_group:`
#       in `on:`, or that context never reports in the queue.
#
# Baseline applied (see assets/branch-protection.json.template):
#   required_conversation_resolution: true   <- the load-bearing field
#   required_approving_review_count:  1      (0 with --solo)
#   allow_force_pushes:               false
#   allow_deletions:                  false
#   required_linear_history:          false  (must be false for merge-commit
#                                             strategy needed by signed commits)
#   enforce_admins:                   false  (explicit; see template comment)
#
# Deliberately tighter-than-default knobs (template ships permissive; raise
# per-repo once your team's signing infra and admin policy are settled):
#
#   Make admins bound by branch protection:
#     gh api repos/OWNER/REPO/branches/<default>/protection/enforce_admins -X POST
#
#   Require GPG/SSH-signed commits (not in template — script never resets it):
#     gh api repos/OWNER/REPO/branches/<default>/protection/required_signatures -X POST
#
# Exit codes:
#   0  - applied successfully, or already compliant
#   1  - drift detected on opinionated fields (per-field diff printed),
#        a --merge-queue precondition refused, or a write failed
#   2  - invalid arguments / template missing
#   3  - repo not found or no access, or protection/rules unreadable
#   4  - default branch ref does not yet exist (empty repo — push first)
#   5  - --from-current-checks: no completed CI run on default branch
#   6  - --merge-queue: a required context never reports on merge_group
#
# SPDX-License-Identifier: MIT
# Copyright (c) Netresearch DTT GmbH

set -euo pipefail

# ---------- output helpers ----------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

err()  { printf '%s\n' "${RED}error:${NC} $*" >&2; }
warn() { printf '%s\n' "${YELLOW}warn:${NC}  $*" >&2; }
info() { printf '%s\n' "${BLUE}info:${NC}  $*" >&2; }
ok()   { printf '%s\n' "${GREEN}ok:${NC}    $*" >&2; }

usage() {
    cat >&2 <<'EOF'
Usage:
  init-branch-protection.sh <owner>/<repo>
  init-branch-protection.sh <owner>/<repo> --from-current-checks
  init-branch-protection.sh <owner>/<repo> --solo
  init-branch-protection.sh <owner>/<repo> --merge-queue

See script header comment for full documentation.
EOF
    exit 2
}

# ---------- arg parsing ----------
[[ $# -ge 1 && $# -le 2 ]] || usage
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

SLUG="$1"
MODE="${2:-apply}"

if [[ "$MODE" != "apply" && "$MODE" != "--from-current-checks" && "$MODE" != "--solo" && "$MODE" != "--merge-queue" ]]; then
    err "unknown second argument: $MODE"
    usage
fi

if [[ ! "$SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    err "expected <owner>/<repo>, got: $SLUG"
    exit 2
fi

OWNER="${SLUG%/*}"
REPO="${SLUG#*/}"

# ---------- locate template ----------
# Script lives at skills/github-project/scripts/init-branch-protection.sh
# Template lives at skills/github-project/assets/branch-protection.json.template
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/../assets/branch-protection.json.template"

if [[ ! -f "$TEMPLATE" ]]; then
    err "template not found at: $TEMPLATE"
    exit 2
fi

# ---------- prerequisites ----------
command -v gh >/dev/null 2>&1 || { err "gh CLI not installed"; exit 2; }
command -v jq >/dev/null 2>&1 || { err "jq not installed"; exit 2; }

# ---------- discover default branch ----------
info "fetching repo metadata for $SLUG ..."
REPO_JSON="$(gh api "repos/$OWNER/$REPO" 2>&1)" || {
    err "cannot access repo $SLUG — not found or no permission"
    printf '%s\n' "$REPO_JSON" >&2
    exit 3
}

DEFAULT_BRANCH="$(jq -r '.default_branch' <<<"$REPO_JSON")"
if [[ -z "$DEFAULT_BRANCH" || "$DEFAULT_BRANCH" == "null" ]]; then
    err "could not determine default branch for $SLUG"
    exit 4
fi
info "default branch: $DEFAULT_BRANCH"

# Verify the default branch actually exists (an empty repo has a `default_branch`
# field set, but the ref does not exist yet — protection PUT would fail with 404).
if ! gh api "repos/$OWNER/$REPO/branches/$DEFAULT_BRANCH" --silent 2>/dev/null; then
    err "default branch '$DEFAULT_BRANCH' does not exist yet (empty repo)"
    err "push an initial commit first, then re-run this script."
    exit 4
fi

PROTECTION_URL="repos/$OWNER/$REPO/branches/$DEFAULT_BRANCH/protection"

# ---------- --merge-queue mode ----------
if [[ "$MODE" == "--merge-queue" ]]; then
    # Org standard (netresearch/t3x-nr-vault, ruleset t3x-baseline). MERGE:
    # the org lands with merge commits, which GitHub signs. 180 minutes: 60
    # was measured to eject green entries under the org's own job backlog
    # (references/merge-strategy.md, "A bulk operation of your own can eject
    # queue entries").
    MQ_PARAMS='{
        "merge_method": "MERGE",
        "grouping_strategy": "ALLGREEN",
        "check_response_timeout_minutes": 180,
        "max_entries_to_build": 10,
        "max_entries_to_merge": 10,
        "min_entries_to_merge": 1,
        "min_entries_to_merge_wait_minutes": 5
    }'
    # Posted by apps against the pull request only; never on a merge_group ref.
    APP_CONTEXTS='["CodeQL","Opengrep OSS","betterleaks","zizmor","SonarCloud Code Analysis"]'

    # ---- reads ----
    if [[ "$(jq -r '.allow_merge_commit' <<<"$REPO_JSON")" != "true" ]]; then
        err "merge commits are disabled on $SLUG (allow_merge_commit is not true)"
        err "the queue merges with MERGE; enable merge commits first:"
        err "  gh api -X PATCH repos/$OWNER/$REPO -F allow_merge_commit=true"
        exit 1
    fi

    if ! RULES="$(gh api "repos/$OWNER/$REPO/rules/branches/$DEFAULT_BRANCH" 2>/dev/null)" \
        || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$RULES"; then
        err "cannot read the rules in effect on $DEFAULT_BRANCH — not writing over an unknown state"
        exit 3
    fi

    PROTECTION_ERR="$(mktemp)"
    trap 'rm -f "$PROTECTION_ERR"' EXIT
    if CLASSIC="$(gh api "$PROTECTION_URL" 2>"$PROTECTION_ERR")"; then
        if [[ -z "$(jq -r '.url // empty' <<<"$CLASSIC" 2>/dev/null)" ]]; then
            err "unexpected branch protection response on $DEFAULT_BRANCH — not writing over an unknown state:"
            printf '%s\n' "$CLASSIC" >&2
            exit 3
        fi
    elif grep -q 'Branch not protected' "$PROTECTION_ERR" - <<<"$CLASSIC"; then
        CLASSIC='{}'
    else
        err "cannot read branch protection on $DEFAULT_BRANCH — not writing over an unknown state:"
        cat "$PROTECTION_ERR" >&2
        exit 3
    fi

    # ---- decide ----
    # Every required context, from classic protection (checks[] is canonical,
    # contexts its deprecated mirror) and from every ruleset in effect.
    REQUIRED="$(jq -n --argjson c "$CLASSIC" --argjson r "$RULES" '
        [ ($c.required_status_checks.contexts // [])[],
          ($c.required_status_checks.checks // [])[].context,
          ($r[] | select(.type == "required_status_checks")
                | .parameters.required_status_checks[]?.context) ] | unique')"

    BAD="$(jq -r --argjson apps "$APP_CONTEXTS" '.[] | select(. as $x | $apps | index($x))' <<<"$REQUIRED")"
    if [[ -n "$BAD" ]]; then
        err "required context(s) that never report on a merge_group ref:"
        while IFS= read -r n; do printf '  - %s\n' "$n" >&2; done <<<"$BAD"
        err "every queue entry would wait for them and time out. Drop them from the"
        err "required checks first; for a code-scanning tool, a ruleset code_scanning rule"
        err "gates the pull request instead. Classic protection: PATCH"
        err "  $PROTECTION_URL/required_status_checks"
        err "with the remaining checks. Ruleset: edit the required_status_checks rule."
        err "No change made."
        exit 6
    fi

    STRICT_RS="$(jq -r '.[] | select(.type == "required_status_checks"
        and .parameters.strict_required_status_checks_policy == true) | .ruleset_id' <<<"$RULES")"
    if [[ -n "$STRICT_RS" ]]; then
        err "ruleset(s) $(tr '\n' ' ' <<<"$STRICT_RS")require branches to be up to date"
        err "(strict_required_status_checks_policy: true). Under a merge queue it must be"
        err "false; this script does not rewrite an existing ruleset. Set it to false in"
        err "the ruleset, then re-run. No change made."
        exit 1
    fi

    EXISTING_MQ="$(jq -c '[.[] | select(.type == "merge_queue")]' <<<"$RULES")"
    NEED_RULESET=true
    if [[ "$(jq 'length' <<<"$EXISTING_MQ")" -gt 0 ]]; then
        DRIFT="$(jq -r --argjson want "$MQ_PARAMS" '.[] | .ruleset_id as $id | .parameters as $p
            | $want | to_entries[] | select($p[.key] != .value)
            | "  ruleset \($id) \(.key): expected=\(.value) actual=\($p[.key])"' <<<"$EXISTING_MQ")"
        if [[ -n "$DRIFT" ]]; then
            warn "a merge queue exists on $DEFAULT_BRANCH with other parameters:"
            printf '%s\n' "$DRIFT" >&2
            warn "not auto-correcting — edit the merge_queue rule in that ruleset by hand."
            exit 1
        fi
        NEED_RULESET=false
        ok "merge queue already in effect on $DEFAULT_BRANCH with the standard parameters"
    fi

    CLASSIC_STRICT="$(jq -r '.required_status_checks.strict // false' <<<"$CLASSIC")"

    if [[ "$(jq 'length' <<<"$REQUIRED")" -eq 0 ]]; then
        warn "no required status checks on $DEFAULT_BRANCH — the queue will gate nothing"
        warn "until some are required (run --from-current-checks after a green CI run)."
    fi

    if [[ "$NEED_RULESET" == "false" && "$CLASSIC_STRICT" != "true" ]]; then
        ok "$SLUG already has the merge queue and strict=false — nothing to do"
        exit 0
    fi

    # ---- writes ----
    if [[ "$NEED_RULESET" == "true" ]]; then
        RULESET_BODY="$(jq -n --argjson p "$MQ_PARAMS" '{
            name: "merge-queue",
            target: "branch",
            enforcement: "active",
            bypass_actors: [],
            conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
            rules: [{type: "merge_queue", parameters: $p}]
        }')"
        info "POST repos/$OWNER/$REPO/rulesets"
        if ! RESP="$(gh api -X POST "repos/$OWNER/$REPO/rulesets" --input - <<<"$RULESET_BODY" 2>&1)"; then
            err "creating the merge-queue ruleset failed:"
            printf '%s\n' "$RESP" >&2
            exit 1
        fi
        RULESET_ID="$(jq -r '.id // empty' <<<"$RESP" 2>/dev/null || true)"
        if [[ -z "$RULESET_ID" ]]; then
            err "ruleset POST answered without an id — check the repository's rulesets:"
            printf '%s\n' "$RESP" >&2
            exit 1
        fi
        # Read back: the answer to the POST is not proof the rule landed.
        BACK="$(gh api "repos/$OWNER/$REPO/rulesets/$RULESET_ID" 2>/dev/null || true)"
        if [[ "$(jq -r --argjson want "$MQ_PARAMS" '
                .enforcement == "active"
                and any(.rules[]?; .type == "merge_queue"
                    and (.parameters as $p | $want | to_entries | all(.value == $p[.key])))' \
                <<<"${BACK:-null}" 2>/dev/null)" != "true" ]]; then
            err "ruleset $RULESET_ID read back without an active merge_queue rule with the standard parameters:"
            printf '%s\n' "$BACK" >&2
            exit 1
        fi
        ok "ruleset $RULESET_ID \"merge-queue\" created; merge queue active on $DEFAULT_BRANCH"
    fi

    if [[ "$CLASSIC_STRICT" == "true" ]]; then
        SUBRES="$PROTECTION_URL/required_status_checks"
        info "PATCH $SUBRES (strict=false)"
        if ! RESP="$(gh api -X PATCH "$SUBRES" --input - <<<'{"strict": false}' 2>&1)"; then
            err "PATCH failed (the queue exists; strict is still true):"
            printf '%s\n' "$RESP" >&2
            exit 1
        fi
        if [[ "$(gh api "$SUBRES" --jq '.strict' 2>/dev/null || true)" != "false" ]]; then
            err "classic strict read back as not false after the PATCH"
            exit 1
        fi
        ok "classic \"require branches to be up to date\" (strict) set to false"
    fi
    info "every workflow producing a required context needs 'merge_group:' in 'on:'"
    exit 0
fi

# ---------- --from-current-checks mode ----------
if [[ "$MODE" == "--from-current-checks" ]]; then
    # Baseline protection MUST already exist — this mode only adds required
    # status checks to it; it never creates protection from scratch.
    if ! CURRENT="$(gh api "$PROTECTION_URL" 2>/dev/null)"; then
        err "no existing branch protection on $SLUG"
        err "run without --from-current-checks first to apply the baseline."
        exit 1
    fi

    # Under a merge queue strict must stay false (see --merge-queue). An
    # unreadable rule set is not read as "no queue": strict=true would then
    # undo the queue's setting.
    if ! RULES="$(gh api "repos/$OWNER/$REPO/rules/branches/$DEFAULT_BRANCH" 2>/dev/null)" \
        || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$RULES"; then
        err "cannot read the rules in effect on $DEFAULT_BRANCH — not writing over an unknown state"
        exit 3
    fi
    STRICT=true
    if [[ "$(jq -r 'any(.[]; .type == "merge_queue")' <<<"$RULES")" == "true" ]]; then
        STRICT=false
        info "a merge queue is in effect on $DEFAULT_BRANCH — strict stays false"
    fi

    info "discovering required status checks from latest commit on $DEFAULT_BRANCH ..."

    # GitHub's required_status_checks.contexts are matched against the
    # check-run *display name* (which includes the "workflow / job" prefix
    # for matrix and called-workflow jobs, e.g. "container-lint / hadolint").
    # The /actions/runs/{id}/jobs endpoint returns the bare job name
    # ("hadolint") — wrong for context matching. We use /commits/{sha}/check-runs
    # against the default branch's HEAD, which returns the canonical
    # check-run names that align with what GitHub compares against
    # required_status_checks.contexts.
    HEAD_SHA="$(gh api "repos/$OWNER/$REPO/commits/$DEFAULT_BRANCH" --jq '.sha // empty' 2>/dev/null || true)"
    if [[ -z "$HEAD_SHA" ]]; then
        err "could not resolve HEAD sha of $DEFAULT_BRANCH"
        exit 5
    fi

    # Sanity-check the commit's overall combined status: if it's not 'success'
    # we may be capturing an incomplete set of checks (e.g., a failing run
    # where some jobs never executed). Warn rather than abort — operator
    # may intentionally be onboarding partial coverage.
    COMBINED="$(gh api "repos/$OWNER/$REPO/commits/$HEAD_SHA/status" --jq '.state // "unknown"' 2>/dev/null || echo unknown)"
    info "using $DEFAULT_BRANCH @ ${HEAD_SHA:0:8} (combined status: $COMBINED)"
    if [[ "$COMBINED" != "success" ]]; then
        warn "combined status is '$COMBINED' (not 'success') — only check-runs that"
        warn "actually completed successfully will be captured. Other contexts that"
        warn "did not run on this commit will NOT be required. Re-run after a fully"
        warn "green CI run on $DEFAULT_BRANCH for complete coverage."
    fi

    # Collect successful check-run names for that commit, deduped.
    mapfile -t CHECK_NAMES < <(gh api --paginate \
        "repos/$OWNER/$REPO/commits/$HEAD_SHA/check-runs?per_page=100" \
        --jq '.check_runs[] | select(.conclusion == "success") | .name' \
        | sort -u)

    if [[ ${#CHECK_NAMES[@]} -eq 0 ]]; then
        err "no successful check-runs found on $DEFAULT_BRANCH @ ${HEAD_SHA:0:8}"
        err "trigger and complete at least one CI run on the default branch,"
        err "then re-run with --from-current-checks."
        exit 5
    fi

    info "discovered ${#CHECK_NAMES[@]} required check(s):"
    for n in "${CHECK_NAMES[@]}"; do printf '  - %s\n' "$n" >&2; done

    CHECKS_JSON="$(printf '%s\n' "${CHECK_NAMES[@]}" | jq -R . | jq -s .)"

    # Status checks already enabled: PATCH only the required_status_checks
    # subresource. It accepts a partial body and leaves all other
    # branch-protection fields untouched.
    if [[ "$(jq -r '.required_status_checks != null' <<<"$CURRENT")" == "true" ]]; then
        SUBRES="$PROTECTION_URL/required_status_checks"
        PATCH_BODY="$(jq -n --argjson checks "$CHECKS_JSON" --argjson strict "$STRICT" \
            '{strict: $strict, contexts: $checks}')"

        info "PATCH $SUBRES"
        if RESP="$(gh api -X PATCH "$SUBRES" --input - <<<"$PATCH_BODY" 2>&1)"; then
            ok "required status checks applied (${#CHECK_NAMES[@]} contexts, strict=$STRICT)"
            exit 0
        else
            err "PATCH failed:"
            printf '%s\n' "$RESP" >&2
            exit 1
        fi
    fi

    # Status checks not enabled: the subresource PATCH answers 404
    # "Required status checks not enabled" — it can update the block, never
    # create it. Re-PUT the whole protection instead, translated from the
    # GET shape ({enabled: bool} wrappers, user/team/app objects) to the PUT
    # shape (bare bools, login/slug strings) so every existing setting is
    # carried over. required_signatures is deliberately absent: it is a
    # separate endpoint and not a PUT field (see header).
    info "required status checks not enabled yet — re-applying protection with them added"
    PUT_BODY="$(jq --argjson checks "$CHECKS_JSON" --argjson strict "$STRICT" '
        def enabled($f): (.[$f].enabled // false);
        def actors: {
            users: [(.users // [])[].login],
            teams: [(.teams // [])[].slug],
            apps:  [(.apps  // [])[].slug]
        };
        {
            required_status_checks: {strict: $strict, contexts: $checks},
            enforce_admins: enabled("enforce_admins"),
            required_pull_request_reviews: (
                .required_pull_request_reviews
                | if . == null then null else
                    {
                        dismiss_stale_reviews: (.dismiss_stale_reviews // false),
                        require_code_owner_reviews: (.require_code_owner_reviews // false),
                        require_last_push_approval: (.require_last_push_approval // false),
                        required_approving_review_count: (.required_approving_review_count // 0)
                    }
                    + (if .dismissal_restrictions then
                        {dismissal_restrictions: (.dismissal_restrictions | actors)} else {} end)
                    + (if .bypass_pull_request_allowances then
                        {bypass_pull_request_allowances: (.bypass_pull_request_allowances | actors)} else {} end)
                  end
            ),
            restrictions: (.restrictions | if . == null then null else actors end),
            required_linear_history: enabled("required_linear_history"),
            allow_force_pushes: enabled("allow_force_pushes"),
            allow_deletions: enabled("allow_deletions"),
            block_creations: enabled("block_creations"),
            required_conversation_resolution: enabled("required_conversation_resolution"),
            lock_branch: enabled("lock_branch"),
            allow_fork_syncing: enabled("allow_fork_syncing")
        }' <<<"$CURRENT")"

    info "PUT $PROTECTION_URL"
    if RESP="$(gh api -X PUT "$PROTECTION_URL" --input - <<<"$PUT_BODY" 2>&1)"; then
        ok "required status checks applied (${#CHECK_NAMES[@]} contexts, strict=$STRICT)"
        ok "all other protection settings carried over from the current state"
        exit 0
    else
        err "PUT failed:"
        printf '%s\n' "$RESP" >&2
        exit 1
    fi
fi

# ---------- apply mode (plain or --solo) ----------
TEMPLATE_BODY="$(cat "$TEMPLATE")"
if [[ "$MODE" == "--solo" ]]; then
    # Single maintainer: an author cannot approve their own pull request, so a
    # required approval would force an admin bypass on every merge.
    TEMPLATE_BODY="$(jq '.required_pull_request_reviews.required_approving_review_count = 0' <<<"$TEMPLATE_BODY")"
fi

# Check whether protection already exists. Only GitHub's explicit "Branch not
# protected" answer means bootstrap: any other failed read (rate limit, auth,
# network) must not lead to a PUT, because the template's
# required_status_checks: null would clear checks already configured.
# stderr is kept apart from the body: a warning gh prints on a successful read
# would otherwise make the JSON unparseable and send the script into the PUT.
PROTECTION_ERR="$(mktemp)"
trap 'rm -f "$PROTECTION_ERR"' EXIT
if EXISTING="$(gh api "$PROTECTION_URL" 2>"$PROTECTION_ERR")"; then
    if [[ -z "$(jq -r '.url // empty' <<<"$EXISTING" 2>/dev/null)" ]]; then
        err "unexpected branch protection response on $DEFAULT_BRANCH — not applying the template over an unknown state:"
        printf '%s\n' "$EXISTING" >&2
        exit 3
    fi
elif grep -q 'Branch not protected' "$PROTECTION_ERR" - <<<"$EXISTING"; then
    EXISTING=""
else
    err "cannot read branch protection on $DEFAULT_BRANCH — not applying the template over an unknown state:"
    cat "$PROTECTION_ERR" >&2
    printf '%s\n' "$EXISTING" >&2
    exit 3
fi

if [[ -n "$EXISTING" ]] && [[ -n "$(jq -r '.url // empty' <<<"$EXISTING" 2>/dev/null)" ]]; then
    info "protection already exists — checking for drift against template baseline"

    # Compare the load-bearing fields from the template against current state.
    # We only flag drift on fields the template OPINIONATES on; fields the
    # template intentionally omits (e.g. required_signatures) are out of scope.
    DRIFT=""
    check_field() {
        local label="$1" expected="$2" actual="$3"
        if [[ "$expected" != "$actual" ]]; then
            DRIFT+="  ${label}: expected=${expected} actual=${actual}"$'\n'
        fi
    }

    EXP_RCR="$(jq -r '.required_conversation_resolution' <<<"$TEMPLATE_BODY")"
    ACT_RCR="$(jq -r '.required_conversation_resolution.enabled // false' <<<"$EXISTING")"
    check_field "required_conversation_resolution" "$EXP_RCR" "$ACT_RCR"

    EXP_APR="$(jq -r '.required_pull_request_reviews.required_approving_review_count' <<<"$TEMPLATE_BODY")"
    ACT_APR="$(jq -r '.required_pull_request_reviews.required_approving_review_count // 0' <<<"$EXISTING")"
    check_field "required_approving_review_count" "$EXP_APR" "$ACT_APR"

    EXP_AFP="$(jq -r '.allow_force_pushes' <<<"$TEMPLATE_BODY")"
    ACT_AFP="$(jq -r '.allow_force_pushes.enabled // false' <<<"$EXISTING")"
    check_field "allow_force_pushes" "$EXP_AFP" "$ACT_AFP"

    EXP_AD="$(jq -r '.allow_deletions' <<<"$TEMPLATE_BODY")"
    ACT_AD="$(jq -r '.allow_deletions.enabled // false' <<<"$EXISTING")"
    check_field "allow_deletions" "$EXP_AD" "$ACT_AD"

    EXP_LH="$(jq -r '.required_linear_history' <<<"$TEMPLATE_BODY")"
    ACT_LH="$(jq -r '.required_linear_history.enabled // false' <<<"$EXISTING")"
    check_field "required_linear_history" "$EXP_LH" "$ACT_LH"

    if [[ -z "$DRIFT" ]]; then
        ok "$SLUG already compliant with template baseline (no drift on opinionated fields)"
        exit 0
    fi

    warn "drift detected vs template baseline:"
    printf '%s' "$DRIFT" >&2
    warn "not auto-correcting — apply the template manually with"
    warn "  gh api -X PUT $PROTECTION_URL --input <skill>/assets/branch-protection.json.template"
    warn "or PATCH specific fields by hand. Aborting to avoid clobbering admin choices."
    exit 1
fi

# No protection yet — apply the template.
info "no existing protection on $DEFAULT_BRANCH — applying template"
if RESP="$(gh api -X PUT "$PROTECTION_URL" --input - <<<"$TEMPLATE_BODY" 2>&1)"; then
    ok "branch protection applied to $SLUG on $DEFAULT_BRANCH"
    ok "required_conversation_resolution: true"
    ok "required_approving_review_count:  $(jq -r '.required_pull_request_reviews.required_approving_review_count' <<<"$TEMPLATE_BODY")"
    info "next steps:"
    info "  1. push at least one CI run on $DEFAULT_BRANCH"
    info "  2. re-run with --from-current-checks to capture required status checks"
    info "  3. (optional) enforce admins:        gh api $PROTECTION_URL/enforce_admins -X POST"
    info "  4. (optional) require signed commits: gh api $PROTECTION_URL/required_signatures -X POST"
    exit 0
else
    err "PUT failed:"
    printf '%s\n' "$RESP" >&2
    exit 1
fi
