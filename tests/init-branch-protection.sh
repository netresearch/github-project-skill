#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
#
# tests/init-branch-protection.sh — behavioural tests for
# skills/github-project/scripts/init-branch-protection.sh.
#
# The script talks to GitHub only through `gh api`. Each case puts a stub
# `gh` first on PATH that answers from files keyed by HTTP method and API
# path, records every call, and keeps the request body the script sends.
# The cases check the exit codes documented in the script header, which
# write requests are sent, and what their bodies contain. Nothing reaches
# GitHub. Requires bash and jq.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT/skills/github-project/scripts/init-branch-protection.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------- gh stub ----------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Answers `gh api` from $STUB_DIR/resp/<METHOD>_<path>.{rc,out,err};
# path separators and query characters become underscores.
[ "${1:-}" = api ] || { echo "stub: unsupported command: $*" >&2; exit 99; }
shift
method=GET path="" jqexpr="" input="" silent=0
while [ $# -gt 0 ]; do
    case "$1" in
        -X) method=$2; shift 2 ;;
        --jq) jqexpr=$2; shift 2 ;;
        --input) input=$2; shift 2 ;;
        --silent) silent=1; shift ;;
        --paginate) shift ;;
        -*) echo "stub: unsupported flag: $1" >&2; exit 99 ;;
        *) path=$1; shift ;;
    esac
done
key="${method}_$(printf '%s' "$path" | tr '/?=&' '____')"
echo "$method $path" >> "$STUB_DIR/calls"
[ "$input" = "-" ] && cat > "$STUB_DIR/body_$key.json"
resp="$STUB_DIR/resp/$key"
if [ ! -f "$resp.rc" ]; then
    echo "stub: no response defined for $method $path" >&2
    exit 98
fi
rc=$(cat "$resp.rc")
[ -f "$resp.err" ] && cat "$resp.err" >&2
if [ -f "$resp.out" ] && [ "$silent" -eq 0 ]; then
    if [ -n "$jqexpr" ] && [ "$rc" -eq 0 ]; then
        jq -r "$jqexpr" "$resp.out"
    else
        cat "$resp.out"
    fi
fi
exit "$rc"
STUB
chmod +x "$WORK/bin/gh"

fail=0
count=0
CASE=""
OUT=""
RC=0

scenario() { # scenario <name> — fresh response set and call log
    CASE="$WORK/$1"
    mkdir -p "$CASE/resp"
    : > "$CASE/calls"
}

respond() { # respond <METHOD> <path> <rc> [stdout] [stderr]
    local key
    key="$1_$(printf '%s' "$2" | tr '/?=&' '____')"
    printf '%s\n' "$3" > "$CASE/resp/$key.rc"
    [ -n "${4:-}" ] && printf '%s\n' "$4" > "$CASE/resp/$key.out"
    [ -n "${5:-}" ] && printf '%s\n' "$5" > "$CASE/resp/$key.err"
    return 0
}

body() { # body <METHOD> <path> — the request body the script sent
    cat "$CASE/body_$1_$(printf '%s' "$2" | tr '/?=&' '____').json" 2>/dev/null
}

run() {
    OUT=$(PATH="$WORK/bin:$PATH" STUB_DIR="$CASE" bash "$SCRIPT" "$@" 2>&1)
    RC=$?
}

report() { # report <description> <ok 0|1> <detail>
    count=$((count + 1))
    if [ "$2" -eq 0 ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1 ($3)"
        printf '%s\n' "$OUT" | sed 's/^/         /'
        [ -s "$CASE/calls" ] && sed 's/^/         call: /' "$CASE/calls"
        fail=1
    fi
}

expect_exit() { # expect_exit <description> <expected-exit>
    local ok=0
    [ "$RC" -eq "$2" ] || ok=1
    report "$1" "$ok" "expected exit $2, got $RC"
}

expect_call() { # expect_call <description> <"METHOD path">
    local ok=0
    grep -qxF -- "$2" "$CASE/calls" || ok=1
    report "$1" "$ok" "no call: $2"
}

expect_no_write() { # expect_no_write <description>
    local ok=0
    if grep -qE '^(PUT|PATCH|POST|DELETE) ' "$CASE/calls"; then ok=1; fi
    report "$1" "$ok" "a write request was sent"
}

expect_json() { # expect_json <description> <json> <jq filter> <expected>
    local actual ok=0
    actual=$(jq -c "$3" <<<"$2" 2>/dev/null)
    [ "$actual" = "$4" ] || ok=1
    report "$1" "$ok" "$3: expected $4, got ${actual:-<no body>}"
}

REPO=repos/acme/widget
PROT=$REPO/branches/main/protection
REPO_OK='{"default_branch":"main"}'
NOT_PROTECTED='gh: Branch not protected (HTTP 404)'

# Protection as GitHub's GET returns it, matching the template baseline.
compliant() { # compliant [approvals] [conversation-resolution]
    jq -nc --argjson a "${1:-1}" --argjson c "${2:-true}" '{
        url: "https://api.github.com/repos/acme/widget/branches/main/protection",
        required_status_checks: null,
        enforce_admins: {enabled: true},
        required_pull_request_reviews: {required_approving_review_count: $a, dismiss_stale_reviews: true},
        required_linear_history: {enabled: false},
        allow_force_pushes: {enabled: false},
        allow_deletions: {enabled: false},
        required_conversation_resolution: {enabled: $c}
    }'
}

echo "arguments"

scenario args
run
expect_exit "no argument exits 2" 2
run acme
expect_exit "slug without owner exits 2" 2
run 'acme/widget;id'
expect_exit "slug with shell metacharacters exits 2" 2
run acme/widget --bogus
expect_exit "unknown mode exits 2" 2
expect_no_write "argument errors send no request"

echo "repository access"

scenario no-access
respond GET "$REPO" 1 '' 'HTTP 404: Not Found'
run acme/widget
expect_exit "inaccessible repository exits 3" 3
expect_no_write "inaccessible repository gets no write"

scenario empty-repo
respond GET "$REPO" 0 "$REPO_OK"
respond GET "$REPO/branches/main" 1 '' 'HTTP 404: Branch not found'
run acme/widget
expect_exit "repository without a default branch ref exits 4" 4
expect_no_write "empty repository gets no write"

echo "baseline"

scenario bootstrap
respond GET "$REPO" 0 "$REPO_OK"
respond GET "$REPO/branches/main" 0 '{}'
respond GET "$PROT" 1 '' "$NOT_PROTECTED"
respond PUT "$PROT" 0 '{}'
run acme/widget
expect_exit "unprotected branch gets the template" 0
expect_call "template is sent with PUT" "PUT $PROT"
sent=$(body PUT "$PROT")
expect_json "conversation resolution is required" "$sent" '.required_conversation_resolution' 'true'
expect_json "one approval is required" "$sent" '.required_pull_request_reviews.required_approving_review_count' '1'
expect_json "force pushes are refused" "$sent" '.allow_force_pushes' 'false'
expect_json "linear history is not required" "$sent" '.required_linear_history' 'false'

scenario solo
respond GET "$REPO" 0 "$REPO_OK"
respond GET "$REPO/branches/main" 0 '{}'
respond GET "$PROT" 1 '' "$NOT_PROTECTED"
respond PUT "$PROT" 0 '{}'
run acme/widget --solo
expect_exit "--solo applies the template" 0
sent=$(body PUT "$PROT")
expect_json "--solo requires no approval" "$sent" '.required_pull_request_reviews.required_approving_review_count' '0'
expect_json "--solo still requires conversation resolution" "$sent" '.required_conversation_resolution' 'true'

scenario unreadable
respond GET "$REPO" 0 "$REPO_OK"
respond GET "$REPO/branches/main" 0 '{}'
respond GET "$PROT" 1 '' 'HTTP 403: API rate limit exceeded'
run acme/widget
expect_exit "unreadable protection exits 3" 3
expect_no_write "unreadable protection is not overwritten"

scenario unexpected
respond GET "$REPO" 0 "$REPO_OK"
respond GET "$REPO/branches/main" 0 '{}'
respond GET "$PROT" 0 '{"message":"something else"}'
run acme/widget
expect_exit "protection response without url exits 3" 3
expect_no_write "unexpected protection response is not overwritten"

scenario compliant
respond GET "$REPO" 0 "$REPO_OK"
respond GET "$REPO/branches/main" 0 '{}'
respond GET "$PROT" 0 "$(compliant)"
run acme/widget
expect_exit "compliant protection exits 0" 0
expect_no_write "compliant protection is left alone"

scenario drift
respond GET "$REPO" 0 "$REPO_OK"
respond GET "$REPO/branches/main" 0 '{}'
respond GET "$PROT" 0 "$(compliant 1 false)"
run acme/widget
expect_exit "drift exits 1" 1
report "drift names the field" "$(grep -qF 'required_conversation_resolution: expected=true actual=false' <<<"$OUT"; echo $?)" "field not named"
expect_no_write "drift is not corrected"

scenario solo-drift
respond GET "$REPO" 0 "$REPO_OK"
respond GET "$REPO/branches/main" 0 '{}'
respond GET "$PROT" 0 "$(compliant 1 true)"
run acme/widget --solo
expect_exit "--solo against one required approval is drift" 1
report "--solo drift names the approval count" "$(grep -qF 'required_approving_review_count: expected=0 actual=1' <<<"$OUT"; echo $?)" "field not named"

echo "--from-current-checks"

checks_repo() { # common responses for --from-current-checks
    respond GET "$REPO" 0 "$REPO_OK"
    respond GET "$REPO/branches/main" 0 '{}'
    respond GET "$REPO/commits/main" 0 '{"sha":"abc1234def"}'
    respond GET "$REPO/commits/abc1234def/status" 0 '{"state":"success"}'
}
RUNS='{"check_runs":[{"name":"lint","conclusion":"success"},{"name":"test","conclusion":"failure"},{"name":"lint","conclusion":"success"},{"name":"build / php","conclusion":"success"}]}'

scenario checks-no-protection
checks_repo
respond GET "$PROT" 1 '' "$NOT_PROTECTED"
run acme/widget --from-current-checks
expect_exit "no baseline protection exits 1" 1
expect_no_write "no baseline gets no write"

scenario checks-patch
checks_repo
respond GET "$PROT" 0 "$(compliant | jq -c '.required_status_checks = {strict: true, contexts: ["old"]}')"
respond GET "$REPO/commits/abc1234def/check-runs?per_page=100" 0 "$RUNS"
respond PATCH "$PROT/required_status_checks" 0 '{}'
run acme/widget --from-current-checks
expect_exit "existing status checks are updated" 0
sent=$(body PATCH "$PROT/required_status_checks")
expect_json "only successful check-runs, deduplicated, are required" "$sent" '.contexts' '["build / php","lint"]'
expect_json "branches must be up to date" "$sent" '.strict' 'true'
report "the whole protection is not re-sent" "$(grep -qxF "PUT $PROT" "$CASE/calls" && echo 1 || echo 0)" "PUT sent"

scenario checks-put
checks_repo
respond GET "$PROT" 0 "$(compliant 2 true)"
respond GET "$REPO/commits/abc1234def/check-runs?per_page=100" 0 "$RUNS"
respond PUT "$PROT" 0 '{}'
run acme/widget --from-current-checks
expect_exit "missing status checks are added" 0
sent=$(body PUT "$PROT")
expect_json "status checks are added" "$sent" '.required_status_checks.contexts' '["build / php","lint"]'
expect_json "approval count is carried over" "$sent" '.required_pull_request_reviews.required_approving_review_count' '2'
expect_json "enforce_admins is carried over" "$sent" '.enforce_admins' 'true'
expect_json "conversation resolution is carried over" "$sent" '.required_conversation_resolution' 'true'
report "no PATCH is tried" "$(grep -q '^PATCH ' "$CASE/calls" && echo 1 || echo 0)" "PATCH sent"

scenario checks-none
checks_repo
respond GET "$PROT" 0 "$(compliant)"
respond GET "$REPO/commits/abc1234def/check-runs?per_page=100" 0 '{"check_runs":[{"name":"test","conclusion":"failure"}]}'
run acme/widget --from-current-checks
expect_exit "no successful check-run exits 5" 5
expect_no_write "no successful check-run gets no write"

echo
if [ "$fail" -ne 0 ]; then
    echo "init-branch-protection.sh: FAILED ($count checks)"
    exit 1
fi
echo "init-branch-protection.sh: all $count checks passed"
