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
# The Nth identical call answers from <key>.N.* when that exists (a read-back
# after a write), otherwise from <key>.*.
nth=$(( $(grep -cxF -- "$method $path" "$STUB_DIR/calls") + 1 ))
echo "$method $path" >> "$STUB_DIR/calls"
[ "$input" = "-" ] && cat > "$STUB_DIR/body_$key.json"
resp="$STUB_DIR/resp/$key"
[ -f "$resp.$nth.rc" ] && resp="$resp.$nth"
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
    respond GET "$REPO/rules/branches/main?per_page=100" 0 '[]'
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

# The org-standard merge_queue parameters, as the rules endpoint returns them.
MQ_STD='{"merge_method":"MERGE","grouping_strategy":"ALLGREEN","check_response_timeout_minutes":180,"max_entries_to_build":10,"max_entries_to_merge":10,"min_entries_to_merge":1,"min_entries_to_merge_wait_minutes":5}'
mq_rule() { # mq_rule [parameters] — one effective merge_queue rule
    jq -nc --argjson p "${1:-$MQ_STD}" '{type: "merge_queue", ruleset_id: 7, ruleset_source_type: "Repository", parameters: $p}'
}

scenario checks-under-queue
checks_repo
respond GET "$REPO/rules/branches/main?per_page=100" 0 "[$(mq_rule)]"
respond GET "$PROT" 0 "$(compliant | jq -c '.required_status_checks = {strict: false, contexts: ["old"]}')"
respond GET "$REPO/commits/abc1234def/check-runs?per_page=100" 0 "$RUNS"
respond PATCH "$PROT/required_status_checks" 0 '{}'
run acme/widget --from-current-checks
expect_exit "status checks under a merge queue are updated" 0
expect_json "under a merge queue branches need not be up to date" "$(body PATCH "$PROT/required_status_checks")" '.strict' 'false'

scenario checks-queue-second-page
checks_repo
respond GET "$REPO/rules/branches/main?per_page=100" 0 "[{\"type\":\"deletion\",\"ruleset_id\":3}][$(mq_rule)]"
respond GET "$PROT" 0 "$(compliant | jq -c '.required_status_checks = {strict: false, contexts: ["old"]}')"
respond GET "$REPO/commits/abc1234def/check-runs?per_page=100" 0 "$RUNS"
respond PATCH "$PROT/required_status_checks" 0 '{}'
run acme/widget --from-current-checks
expect_exit "status checks under a queue on the second page of rules are updated" 0
expect_json "a queue on the second page keeps strict false" "$(body PATCH "$PROT/required_status_checks")" '.strict' 'false'

scenario checks-rules-unreadable
checks_repo
respond GET "$REPO/rules/branches/main?per_page=100" 1 '' 'HTTP 403: API rate limit exceeded'
respond GET "$PROT" 0 "$(compliant | jq -c '.required_status_checks = {strict: false, contexts: ["old"]}')"
respond GET "$REPO/commits/abc1234def/check-runs?per_page=100" 0 "$RUNS"
respond PATCH "$PROT/required_status_checks" 0 '{}'
run acme/widget --from-current-checks
expect_exit "unreadable rules exit 3" 3
expect_no_write "unreadable rules get no write"

echo "--merge-queue"

RULESETS=$REPO/rulesets
mq_repo() { # mq_repo [allow_merge_commit] [allow_auto_merge] — common responses for --merge-queue
    respond GET "$REPO" 0 "$(jq -nc --argjson m "${1:-true}" --argjson a "${2:-true}" \
        '{default_branch: "main", allow_merge_commit: $m, allow_auto_merge: $a}')"
    respond GET "$REPO/branches/main" 0 '{}'
    return 0
}
classic_checks() { # classic_checks <strict> <checks-json> — protection with required checks
    compliant | jq -c --argjson s "$1" --argjson k "$2" \
        '.required_status_checks = {strict: $s, contexts: [$k[].context], checks: $k}'
}
LINT='[{"context":"lint","app_id":15368}]'
CREATED="$(jq -nc --argjson p "$MQ_STD" '{id: 42, enforcement: "active", rules: [{type: "merge_queue", parameters: $p}]}')"

scenario mq-create
mq_repo
respond GET "$REPO/rules/branches/main?per_page=100" 0 '[]'
respond GET "$PROT" 0 "$(classic_checks true "$LINT")"
respond POST "$RULESETS" 0 '{"id":42}'
respond GET "$RULESETS/42" 0 "$CREATED"
respond PATCH "$PROT/required_status_checks" 0 '{}'
respond GET "$PROT/required_status_checks" 0 '{"strict":false}'
run acme/widget --merge-queue
expect_exit "--merge-queue creates the queue" 0
expect_call "a ruleset is created" "POST $RULESETS"
sent=$(body POST "$RULESETS")
expect_json "the ruleset targets the default branch" "$sent" '.conditions.ref_name.include' '["~DEFAULT_BRANCH"]'
expect_json "the ruleset is active" "$sent" '.enforcement' '"active"'
expect_json "the ruleset carries only the merge_queue rule" "$sent" '[.rules[].type]' '["merge_queue"]'
expect_json "the queue uses the org parameters" "$sent" '.rules[0].parameters' "$(jq -c . <<<"$MQ_STD")"
expect_json "nobody bypasses the queue" "$sent" '.bypass_actors' '[]'
expect_call "the ruleset is read back" "GET $RULESETS/42"
expect_json "classic strict is turned off" "$(body PATCH "$PROT/required_status_checks")" '.' '{"strict":false}'
report "classic protection is not re-sent" "$(grep -qxF "PUT $PROT" "$CASE/calls" && echo 1 || echo 0)" "PUT sent"

scenario mq-noop
mq_repo
respond GET "$REPO/rules/branches/main?per_page=100" 0 "[$(mq_rule)]"
respond GET "$PROT" 0 "$(classic_checks false "$LINT")"
run acme/widget --merge-queue
expect_exit "an existing standard queue exits 0" 0
expect_no_write "an existing standard queue with strict=false is left alone"

scenario mq-second-page
mq_repo
# gh --paginate prints one array per page; the queue sits on the second one.
respond GET "$REPO/rules/branches/main?per_page=100" 0 "[{\"type\":\"deletion\",\"ruleset_id\":3}][$(mq_rule)]"
respond GET "$PROT" 0 "$(classic_checks false "$LINT")"
run acme/widget --merge-queue
expect_exit "a queue on the second page of rules is found" 0
expect_no_write "a queue on the second page gets no second ruleset"

scenario mq-existing-strict
mq_repo
respond GET "$REPO/rules/branches/main?per_page=100" 0 "[$(mq_rule)]"
respond GET "$PROT" 0 "$(classic_checks true "$LINT")"
respond PATCH "$PROT/required_status_checks" 0 '{}'
respond GET "$PROT/required_status_checks" 0 '{"strict":false}'
run acme/widget --merge-queue
expect_exit "an existing queue with strict=true gets strict turned off" 0
report "no second ruleset is created" "$(grep -q "^POST " "$CASE/calls" && echo 1 || echo 0)" "POST sent"
expect_json "strict is sent as false" "$(body PATCH "$PROT/required_status_checks")" '.strict' 'false'

scenario mq-no-classic-checks
mq_repo
respond GET "$REPO/rules/branches/main?per_page=100" 0 '[]'
respond GET "$PROT" 0 "$(compliant)"
respond POST "$RULESETS" 0 '{"id":42}'
respond GET "$RULESETS/42" 0 "$CREATED"
run acme/widget --merge-queue
expect_exit "a queue without classic status checks is created" 0
report "no strict PATCH without a status-check block" "$(grep -q '^PATCH ' "$CASE/calls" && echo 1 || echo 0)" "PATCH sent"
report "zero required checks are warned about" "$(grep -qF 'the queue will gate nothing' <<<"$OUT"; echo $?)" "no warning"

scenario mq-app-context-classic
mq_repo
respond GET "$REPO/rules/branches/main?per_page=100" 0 '[]'
respond GET "$PROT" 0 "$(classic_checks true '[{"context":"lint","app_id":15368},{"context":"CodeQL","app_id":57789}]')"
run acme/widget --merge-queue
expect_exit "a required CodeQL context exits 6" 6
report "the refusal names the context" "$(grep -qF -- '- CodeQL' <<<"$OUT"; echo $?)" "context not named"
report "the refusal prints the PATCH keeping the other checks" "$(grep -qF -- "--input - <<<'{\"strict\":false,\"checks\":[{\"context\":\"lint\",\"app_id\":15368}]}'" <<<"$OUT"; echo $?)" "PATCH command missing"
expect_no_write "a required app context gets no write"

scenario mq-app-context-legacy
mq_repo
respond GET "$REPO/rules/branches/main?per_page=100" 0 '[]'
respond GET "$PROT" 0 "$(compliant | jq -c '.required_status_checks = {strict: true, contexts: ["lint", "zizmor"], checks: []}')"
run acme/widget --merge-queue
expect_exit "a required zizmor context in contexts[] exits 6" 6
report "the PATCH keeps contexts[]-only checks for any app" "$(grep -qF -- "<<<'{\"strict\":false,\"checks\":[{\"context\":\"lint\",\"app_id\":-1}]}'" <<<"$OUT"; echo $?)" "lint dropped or pinned"

DEFAULT_SETUP=$REPO/code-scanning/default-setup
# This repository's own required checks (2026-10-21): CodeQL default setup
# posts "Analyze (<language>)" under the GitHub Actions app; DCO is unpinned.
DS_CHECKS='[{"context":"Analyze (actions)","app_id":15368},{"context":"lint","app_id":15368},{"context":"DCO","app_id":null}]'

scenario mq-default-setup-analyze
mq_repo
respond GET "$REPO/rules/branches/main?per_page=100" 0 '[{"type":"required_status_checks","ruleset_id":9,"parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"Analyze (python)","integration_id":15368}]}}]'
respond GET "$PROT" 0 "$(classic_checks true "$DS_CHECKS")"
respond GET "$DEFAULT_SETUP" 0 '{"state":"configured","languages":["actions","python"]}'
run acme/widget --merge-queue
expect_exit "a required default-setup Analyze context exits 6" 6
report "the refusal names the Analyze context" "$(grep -qF -- '- Analyze (actions)' <<<"$OUT"; echo $?)" "context not named"
report "the refusal names the ruleset-required Analyze context" "$(grep -qF 'Ruleset(s) 9: remove them' <<<"$OUT"; echo $?)" "ruleset not named"
report "the refusal names the shared CodeQL workflow as the remedy" "$(grep -qF 'netresearch/.github/.github/workflows/codeql.yml@main' <<<"$OUT"; echo $?)" "remedy missing"
report "the remedy disables default setup first" "$(grep -qF 'code-scanning/default-setup -f state=not-configured' <<<"$OUT"; echo $?)" "disable step missing"
report "the PATCH keeps an unpinned context for any app (-1)" "$(grep -qF -- "<<<'{\"strict\":false,\"checks\":[{\"context\":\"lint\",\"app_id\":15368},{\"context\":\"DCO\",\"app_id\":-1}]}'" <<<"$OUT"; echo $?)" "PATCH command wrong"
expect_no_write "a required default-setup Analyze context gets no write"

scenario mq-default-setup-off
mq_repo
respond GET "$REPO/rules/branches/main?per_page=100" 0 '[]'
respond GET "$PROT" 0 "$(classic_checks false "$DS_CHECKS")"
respond GET "$DEFAULT_SETUP" 0 '{"state":"not-configured","languages":[]}'
respond POST "$RULESETS" 0 '{"id":42}'
respond GET "$RULESETS/42" 0 "$CREATED"
run acme/widget --merge-queue
expect_exit "an Analyze context without default setup is allowed" 0
expect_call "the queue is created without default setup" "POST $RULESETS"

scenario mq-codeql-workflow-analyze
mq_repo
respond GET "$REPO/rules/branches/main?per_page=100" 0 '[]'
respond GET "$PROT" 0 "$(classic_checks false '[{"context":"codeql / Analyze (python)","app_id":15368}]')"
respond GET "$DEFAULT_SETUP" 0 '{"state":"configured","languages":["python"]}'
respond POST "$RULESETS" 0 '{"id":42}'
respond GET "$RULESETS/42" 0 "$CREATED"
run acme/widget --merge-queue
expect_exit "a workflow-prefixed codeql / Analyze context is allowed" 0
expect_call "the queue is created next to a workflow Analyze job" "POST $RULESETS"

# netresearch/enterprise-readiness-skill on 2026-10-22: the merge-queue ruleset
# carries a code_scanning rule for CodeQL while default setup is configured, and
# fork pull requests #151 and #152 stayed BLOCKED with every check green.
ERS_RULES='[{"type":"deletion","ruleset_id":14507403,"parameters":null},{"type":"non_fast_forward","ruleset_id":14507403,"parameters":null},{"type":"copilot_code_review","ruleset_id":14507403,"parameters":{"review_on_push":false,"review_draft_pull_requests":false}},{"type":"merge_queue","ruleset_id":25562807,"parameters":{"merge_method":"MERGE","max_entries_to_build":10,"min_entries_to_merge":1,"max_entries_to_merge":10,"min_entries_to_merge_wait_minutes":5,"grouping_strategy":"ALLGREEN","check_response_timeout_minutes":180}},{"type":"code_scanning","ruleset_id":25562807,"parameters":{"code_scanning_tools":[{"tool":"CodeQL","security_alerts_threshold":"high_or_higher","alerts_threshold":"errors"}]}}]'
ERS_CHECKS='[{"context":"Skill Validation / Skill Validation","app_id":15368},{"context":"eval-validate / Eval Validation","app_id":15368},{"context":"DCO","app_id":null},{"context":"tests / Skill Tests","app_id":15368},{"context":"All security checks","app_id":15368}]'

scenario mq-codeql-rule-default-setup
mq_repo
respond GET "$REPO/rules/branches/main?per_page=100" 0 "$ERS_RULES"
respond GET "$PROT" 0 "$(classic_checks false "$ERS_CHECKS")"
respond GET "$DEFAULT_SETUP" 0 '{"state":"configured","languages":["actions","python"]}'
run acme/widget --merge-queue
expect_exit "a code_scanning rule for CodeQL next to default setup exits 6" 6
report "the refusal says fork pull requests stay blocked" "$(grep -qF 'every fork pull request' <<<"$OUT"; echo $?)" "fork cause missing"
report "the refusal names the shared CodeQL workflow" "$(grep -qF 'netresearch/.github/.github/workflows/codeql.yml@main' <<<"$OUT"; echo $?)" "remedy missing"
expect_no_write "a code_scanning rule next to default setup gets no write"

scenario mq-codeql-rule-advanced-setup
mq_repo
respond GET "$REPO/rules/branches/main?per_page=100" 0 "$ERS_RULES"
respond GET "$PROT" 0 "$(classic_checks false "$ERS_CHECKS")"
respond GET "$DEFAULT_SETUP" 0 '{"state":"not-configured","languages":[]}'
run acme/widget --merge-queue
expect_exit "a code_scanning rule for CodeQL without default setup is accepted" 0
report "the existing standard queue is left alone" "$(grep -qF 'nothing to do' <<<"$OUT"; echo $?)" "queue not recognised"
expect_no_write "an accepted standard queue gets no write"

scenario mq-default-setup-unreadable
mq_repo
respond GET "$REPO/rules/branches/main?per_page=100" 0 '[]'
respond GET "$PROT" 0 "$(classic_checks false "$DS_CHECKS")"
respond GET "$DEFAULT_SETUP" 1 '' 'HTTP 403: Resource not accessible by integration'
respond POST "$RULESETS" 0 '{"id":42}'
respond GET "$RULESETS/42" 0 "$CREATED"
run acme/widget --merge-queue
expect_exit "an unreadable default setup with an Analyze context exits 3" 3
expect_no_write "an unreadable default setup gets no write"

scenario mq-app-context-ruleset
mq_repo
respond GET "$REPO/rules/branches/main?per_page=100" 0 '[{"type":"required_status_checks","ruleset_id":9,"parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"SonarCloud Code Analysis"}]}}]'
respond GET "$PROT" 1 '' "$NOT_PROTECTED"
run acme/widget --merge-queue
expect_exit "a ruleset-required SonarCloud context exits 6" 6
report "the refusal names the ruleset" "$(grep -qF 'Ruleset(s) 9: remove them' <<<"$OUT"; echo $?)" "ruleset not named"
expect_no_write "a ruleset-required app context gets no write"

scenario mq-actions-job-named-like-app
mq_repo
# A workflow job called zizmor, pinned to GitHub Actions: it reports on merge_group.
respond GET "$REPO/rules/branches/main?per_page=100" 0 '[{"type":"required_status_checks","ruleset_id":9,"parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"zizmor","integration_id":15368}]}}]'
respond GET "$PROT" 0 "$(classic_checks true '[{"context":"lint","app_id":15368},{"context":"betterleaks","app_id":15368},{"context":"CodeQL","app_id":57789}]')"
run acme/widget --merge-queue
expect_exit "an app context next to Actions-pinned namesakes exits 6" 6
report "an Actions-pinned namesake is not named" "$(grep -qF -- '- betterleaks' <<<"$OUT" && echo 1 || echo 0)" "betterleaks named"
report "the PATCH keeps the Actions-pinned namesake" "$(grep -qF -- "<<<'{\"strict\":false,\"checks\":[{\"context\":\"lint\",\"app_id\":15368},{\"context\":\"betterleaks\",\"app_id\":15368}]}'" <<<"$OUT"; echo $?)" "namesake dropped"
report "a ruleset with only an Actions-pinned namesake is not named" "$(grep -qF 'Ruleset(s)' <<<"$OUT" && echo 1 || echo 0)" "ruleset named"

scenario mq-drift
mq_repo
respond GET "$REPO/rules/branches/main?per_page=100" 0 "[$(mq_rule "$(jq -c '.merge_method = "SQUASH" | .check_response_timeout_minutes = 30' <<<"$MQ_STD")")]"
respond GET "$PROT" 0 "$(classic_checks true "$LINT")"
run acme/widget --merge-queue
expect_exit "a queue with other parameters exits 1" 1
report "drift names the parameter" "$(grep -qF 'merge_method: expected=MERGE actual=SQUASH' <<<"$OUT"; echo $?)" "parameter not named"
expect_no_write "a drifted queue is not corrected"

scenario mq-ruleset-strict
mq_repo
respond GET "$REPO/rules/branches/main?per_page=100" 0 '[{"type":"required_status_checks","ruleset_id":9,"parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"lint"}]}}]'
respond GET "$PROT" 1 '' "$NOT_PROTECTED"
run acme/widget --merge-queue
expect_exit "a ruleset requiring up-to-date branches exits 1" 1
expect_no_write "a strict ruleset is not rewritten"

scenario mq-no-merge-commit
mq_repo false
respond GET "$REPO/rules/branches/main?per_page=100" 0 '[]'
respond GET "$PROT" 0 "$(classic_checks true "$LINT")"
respond POST "$RULESETS" 0 '{"id":42}'
respond GET "$RULESETS/42" 0 "$CREATED"
respond PATCH "$PROT/required_status_checks" 0 '{}'
respond GET "$PROT/required_status_checks" 0 '{"strict":false}'
run acme/widget --merge-queue
expect_exit "disabled merge commits exit 1" 1
expect_no_write "disabled merge commits get no write"

scenario mq-rules-unreadable
mq_repo
respond GET "$REPO/rules/branches/main?per_page=100" 1 '' 'HTTP 403: API rate limit exceeded'
respond GET "$PROT" 0 "$(classic_checks true "$LINT")"
respond POST "$RULESETS" 0 '{"id":42}'
respond GET "$RULESETS/42" 0 "$CREATED"
respond PATCH "$PROT/required_status_checks" 0 '{}'
respond GET "$PROT/required_status_checks" 0 '{"strict":false}'
run acme/widget --merge-queue
expect_exit "unreadable rules exit 3" 3
expect_no_write "unreadable rules get no write"

scenario mq-auto-merge-off
# An existing standard queue with strict=false, but allow_auto_merge false:
# measured 2026-10-21/22, `gh pr merge --auto` then fails with "Auto merge is
# not allowed for this repository".
mq_repo true false
respond GET "$REPO/rules/branches/main?per_page=100" 0 "[$(mq_rule)]"
respond GET "$PROT" 0 "$(classic_checks false "$LINT")"
respond PATCH "$REPO" 0 '{}'
respond GET "$REPO.2" 0 '{"default_branch":"main","allow_merge_commit":true,"allow_auto_merge":true}'
run acme/widget --merge-queue
expect_exit "disallowed auto-merge next to a standard queue is fixed" 0
expect_call "auto-merge is allowed on the repository" "PATCH $REPO"
expect_json "allow_auto_merge is sent as true" "$(body PATCH "$REPO")" '.' '{"allow_auto_merge":true}'
report "allow_auto_merge is read back" "$([[ "$(grep -cxF "GET $REPO" "$CASE/calls")" -eq 2 ]] && echo 0 || echo 1)" "no second GET $REPO"
report "no ruleset is created for an existing queue" "$(grep -q "^POST " "$CASE/calls" && echo 1 || echo 0)" "POST sent"

scenario mq-auto-merge-readback
mq_repo true false
respond GET "$REPO/rules/branches/main?per_page=100" 0 "[$(mq_rule)]"
respond GET "$PROT" 0 "$(classic_checks false "$LINT")"
respond PATCH "$REPO" 0 '{}'
run acme/widget --merge-queue
expect_exit "allow_auto_merge read back as false exits 1" 1

scenario mq-auto-merge-refused
# A refused precondition writes nothing, auto-merge included.
mq_repo true false
respond GET "$REPO/rules/branches/main?per_page=100" 0 "[$(mq_rule "$(jq -c '.check_response_timeout_minutes = 60' <<<"$MQ_STD")")]"
respond GET "$PROT" 0 "$(classic_checks false "$LINT")"
respond PATCH "$REPO" 0 '{}'
run acme/widget --merge-queue
expect_exit "a drifted queue with disallowed auto-merge exits 1" 1
expect_no_write "a drifted queue does not get auto-merge allowed either"

scenario mq-readback
mq_repo
respond GET "$REPO/rules/branches/main?per_page=100" 0 '[]'
respond GET "$PROT" 0 "$(classic_checks true "$LINT")"
respond POST "$RULESETS" 0 '{"id":42}'
respond GET "$RULESETS/42" 0 '{"id":42,"enforcement":"active","rules":[]}'
run acme/widget --merge-queue
expect_exit "a ruleset read back without the queue exits 1" 1
report "strict is not touched after a failed read-back" "$(grep -q '^PATCH ' "$CASE/calls" && echo 1 || echo 0)" "PATCH sent"

echo
if [ "$fail" -ne 0 ]; then
    echo "init-branch-protection.sh: FAILED ($count checks)"
    exit 1
fi
echo "init-branch-protection.sh: all $count checks passed"
