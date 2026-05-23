#!/usr/bin/env bash
# init-branch-protection.sh
# Apply Netresearch standard branch protection to a GitHub repository.
#
# This is the REQUIRED first step after `gh repo create`, before pushing the
# first commit or opening the first PR. The structural enforcement applied
# here (required_conversation_resolution + min-1-approver) is what makes the
# unresolved-threads workflow rule actually safe — relying only on operator
# discipline has demonstrably failed (see netresearch/snipe-it-docker-compose-stack#17).
#
# Usage:
#   bash init-branch-protection.sh <owner>/<repo>
#       Apply baseline protection (no required status checks yet — for new
#       repos with no CI history). Idempotent: a second run on an already-
#       compliant repo reports drift (or "already compliant") and exits 0.
#
#   bash init-branch-protection.sh <owner>/<repo> --from-current-checks
#       Follow-up after the first successful CI run. Reads the check-run names
#       from the most recent completed workflow run on the default branch and
#       PATCHes them in as required status contexts with strict=true.
#
# Baseline applied (see assets/branch-protection.json.template):
#   required_conversation_resolution: true   <- the load-bearing field
#   required_approving_review_count:  1
#   allow_force_pushes:               false
#   allow_deletions:                  false
#   required_linear_history:          false  (must be false for merge-commit
#                                             strategy needed by signed commits)
#
# Deliberately NOT in the template (per Netresearch org policy 2026-05):
#   enforce_admins:      shipped as false; tighten per-repo via:
#     gh api repos/OWNER/REPO/branches/<default>/protection/enforce_admins -X POST
#   required_signatures: omitted entirely (not set to false) so this script
#     never resets a repo that has already enabled signing. Tighten per-repo:
#     gh api repos/OWNER/REPO/branches/<default>/protection/required_signatures -X POST
#
# Exit codes:
#   0  - applied or already compliant
#   1  - drift detected (reported, not auto-corrected on second run)
#   2  - invalid arguments / template missing
#   3  - repo not found or no access
#   4  - default branch does not yet exist (empty repo — push initial commit first)
#   5  - --from-current-checks: no completed workflow run found on default branch
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
    info "discovering required status checks from latest workflow run on $DEFAULT_BRANCH ..."

    # Find the most recent completed run on the default branch.
    RUN_ID="$(gh api \
        "repos/$OWNER/$REPO/actions/runs?branch=$DEFAULT_BRANCH&status=completed&per_page=1" \
        --jq '.workflow_runs[0].id // empty' 2>/dev/null || true)"

    if [[ -z "$RUN_ID" ]]; then
        err "no completed workflow run found on $DEFAULT_BRANCH"
        err "trigger and complete at least one CI run, then re-run with --from-current-checks."
        exit 5
    fi
    info "using run id: $RUN_ID"

    # Collect successful check-run names from that run.
    mapfile -t CHECK_NAMES < <(gh api --paginate \
        "repos/$OWNER/$REPO/actions/runs/$RUN_ID/jobs" \
        --jq '.jobs[] | select(.conclusion == "success") | .name')

    if [[ ${#CHECK_NAMES[@]} -eq 0 ]]; then
        err "no successful jobs found in latest run; nothing to require."
        exit 5
    fi

    info "discovered ${#CHECK_NAMES[@]} required check(s):"
    for n in "${CHECK_NAMES[@]}"; do printf '  - %s\n' "$n" >&2; done

    # Build a JSON body that updates only required_status_checks. We PATCH the
    # protection endpoint by re-PUTting the merged document: GitHub's API for
    # branch protection does not accept partial bodies, so we read existing
    # protection, splice the new contexts in, and PUT back.
    EXISTING="$(gh api "$PROTECTION_URL" 2>/dev/null || echo '{}')"

    # If protection has not been initialized yet, fall back to the template.
    if [[ "$EXISTING" == "{}" ]] || [[ -z "$(jq -r '.url // empty' <<<"$EXISTING")" ]]; then
        warn "no existing protection — applying baseline first then adding checks"
        EXISTING="$(cat "$TEMPLATE")"
    fi

    # Normalize the existing protection into a PUT-compatible body (the GET
    # response includes embedded `url` fields and nested envelopes that the
    # PUT endpoint rejects).
    PUT_BODY="$(jq \
        --argjson checks "$(printf '%s\n' "${CHECK_NAMES[@]}" | jq -R . | jq -s .)" \
        '{
            required_status_checks: {
                strict: true,
                contexts: $checks
            },
            enforce_admins: (.enforce_admins.enabled // false),
            required_pull_request_reviews: (
                if .required_pull_request_reviews then {
                    required_approving_review_count: (.required_pull_request_reviews.required_approving_review_count // 1),
                    dismiss_stale_reviews: (.required_pull_request_reviews.dismiss_stale_reviews // false),
                    require_code_owner_reviews: (.required_pull_request_reviews.require_code_owner_reviews // false),
                    require_last_push_approval: (.required_pull_request_reviews.require_last_push_approval // false)
                } else {
                    required_approving_review_count: 1,
                    dismiss_stale_reviews: false,
                    require_code_owner_reviews: false,
                    require_last_push_approval: false
                } end
            ),
            restrictions: null,
            required_linear_history: (.required_linear_history.enabled // false),
            allow_force_pushes: (.allow_force_pushes.enabled // false),
            allow_deletions: (.allow_deletions.enabled // false),
            required_conversation_resolution: (.required_conversation_resolution.enabled // true),
            lock_branch: (.lock_branch.enabled // false),
            allow_fork_syncing: (.allow_fork_syncing.enabled // false)
        }' <<<"$EXISTING")"

    info "PUT $PROTECTION_URL (with required checks)"
    if RESP="$(gh api -X PUT "$PROTECTION_URL" --input - <<<"$PUT_BODY" 2>&1)"; then
        ok "required status checks applied (${#CHECK_NAMES[@]} contexts, strict=true)"
        exit 0
    else
        err "PUT failed:"
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
    warn "not auto-correcting — re-run without --from-current-checks intentionally,"
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
