#!/usr/bin/env bash
# init-branch-protection.sh
# Apply Netresearch standard branch protection to a GitHub repository.
#
# REQUIRED step after `gh repo create` + initial push, BEFORE opening the
# first PR. (The default branch ref must exist — push your initial commit
# first; this script exits 4 on empty repos.) The structural enforcement
# applied here (required_conversation_resolution + min-1-approver) is what
# makes the unresolved-threads workflow rule actually safe — operator
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
#       from /commits/{default_branch}/check-runs and PATCHes them in via
#       the .../protection/required_status_checks subresource (so other
#       branch-protection fields — bypass_pull_request_allowances,
#       dismissal_restrictions, etc. — are untouched).
#
# Baseline applied (see assets/branch-protection.json.template):
#   required_conversation_resolution: true   <- the load-bearing field
#   required_approving_review_count:  1
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
#        or a PUT/PATCH failed
#   2  - invalid arguments / template missing
#   3  - repo not found or no access
#   4  - default branch ref does not yet exist (empty repo — push first)
#   5  - --from-current-checks: no completed CI run on default branch
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

See script header comment for full documentation.
EOF
    exit 2
}

# ---------- arg parsing ----------
[[ $# -ge 1 && $# -le 2 ]] || usage
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

SLUG="$1"
MODE="${2:-apply}"

if [[ "$MODE" != "apply" && "$MODE" != "--from-current-checks" ]]; then
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

# ---------- --from-current-checks mode ----------
if [[ "$MODE" == "--from-current-checks" ]]; then
    # Baseline protection MUST already exist — we PATCH the
    # required_status_checks subresource only. This avoids clobbering
    # fields the apply-mode template does not enumerate (e.g.
    # bypass_pull_request_allowances, dismissal_restrictions, or any
    # field GitHub adds later).
    if ! gh api "$PROTECTION_URL" --silent 2>/dev/null; then
        err "no existing branch protection on $SLUG"
        err "run without --from-current-checks first to apply the baseline."
        exit 1
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

    # PATCH only the required_status_checks subresource. This endpoint
    # accepts a partial body and leaves all other branch-protection fields
    # untouched — the safe way to add required checks without enumerating
    # (and potentially dropping) other settings.
    SUBRES="$PROTECTION_URL/required_status_checks"
    PATCH_BODY="$(jq -n \
        --argjson checks "$(printf '%s\n' "${CHECK_NAMES[@]}" | jq -R . | jq -s .)" \
        '{strict: true, contexts: $checks}')"

    info "PATCH $SUBRES"
    if RESP="$(gh api -X PATCH "$SUBRES" --input - <<<"$PATCH_BODY" 2>&1)"; then
        ok "required status checks applied (${#CHECK_NAMES[@]} contexts, strict=true)"
        exit 0
    else
        err "PATCH failed:"
        printf '%s\n' "$RESP" >&2
        exit 1
    fi
fi

# ---------- apply mode ----------
TEMPLATE_BODY="$(cat "$TEMPLATE")"

# Check whether protection already exists.
EXISTING="$(gh api "$PROTECTION_URL" 2>/dev/null || echo '')"

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
    ok "required_approving_review_count:  1"
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
