#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
#
# tests/verify-github-project.sh — behavioural tests for
# skills/github-project/scripts/verify-github-project.sh.
#
# Each case builds a fixture directory, runs the verifier against it, and
# checks the exit code and lines of the output. Only the dotted-name fixture
# has a github.com `origin`; the two remote fixtures run with a stub `gh` on
# PATH that records and answers every call, so no fixture reaches the
# network. Requires bash and git.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT/skills/github-project/scripts/verify-github-project.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
count=0
OUT=""
RC=0

# run <args...> — runs the verifier, stores the output without colour codes
# in OUT and the exit code in RC.
run() {
    OUT=$(bash "$SCRIPT" "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
    RC=${PIPESTATUS[0]}
}

report() { # report <description> <ok 0|1> [detail]
    count=$((count + 1))
    if [ "$2" -eq 0 ]; then
        echo "  ok   $1"
    else
        echo "  FAIL $1${3:+ ($3)}"
        printf '%s\n' "$OUT" | sed 's/^/         /'
        fail=1
    fi
}

expect_exit() { # expect_exit <description> <expected-exit>
    local ok=0
    [ "$RC" -eq "$2" ] || ok=1
    report "$1" "$ok" "expected exit $2, got $RC"
}

expect_line() { # expect_line <description> <fixed string>
    local ok=0
    grep -qF -- "$2" <<<"$OUT" || ok=1
    report "$1" "$ok" "missing line: $2"
}

expect_no_line() { # expect_no_line <description> <fixed string>
    local ok=0
    if grep -qF -- "$2" <<<"$OUT"; then ok=1; fi
    report "$1" "$ok" "unexpected line: $2"
}

expect_count() { # expect_count <description> <fixed string> <expected count>
    local n
    n=$(grep -cF -- "$2" <<<"$OUT")
    local ok=0
    [ "$n" -eq "$3" ] || ok=1
    report "$1" "$ok" "expected $3 lines with '$2', got $n"
}

# The verifier prints one "━━━ <section> ━━━" header per section.
SECTIONS=12

echo "arguments"

run
expect_exit "no argument exits 2" 2

run "$WORK/does-not-exist"
expect_exit "missing directory exits 2" 2

echo "empty directory"

mkdir -p "$WORK/empty"
run "$WORK/empty"
expect_exit "empty directory fails" 1
expect_count "every section runs" "━━━" "$SECTIONS"
expect_line "missing README.md is a failure" "✗ README.md missing"
expect_no_line "a missing README.md is not reported as present" "README.md exists"
expect_line "missing dependency automation is a failure" "✗ No dependency management (Dependabot or Renovate) configured"
expect_line "summary counts the five failures" "Failed:     5"

echo "partial directory"

mkdir -p "$WORK/partial"
touch "$WORK/partial/README.md"
run "$WORK/partial"
expect_count "README.md is reported once as present" "README.md exists" 1
expect_no_line "a present README.md is not reported as missing" "README.md missing"
expect_count "every section runs after the first pass" "━━━" "$SECTIONS"

echo "complete directory"

full="$WORK/full"
mkdir -p "$full/.github/workflows" "$full/.github/ISSUE_TEMPLATE"
touch "$full/README.md" "$full/LICENSE" "$full/SECURITY.md" "$full/CONTRIBUTING.md" \
    "$full/CODE_OF_CONDUCT.md" "$full/CHANGELOG.md" \
    "$full/.github/ISSUE_TEMPLATE/bug_report.md" "$full/.github/ISSUE_TEMPLATE/feature_request.md"
printf '* @example/maintainers\n' > "$full/.github/CODEOWNERS"
printf 'version: 2\nupdates:\n  - package-ecosystem: github-actions\n    groups:\n      all:\n        patterns: ["*"]\n' \
    > "$full/.github/dependabot.yml"
printf 'on: pull_request_target\npermissions: {}\njobs:\n  merge:\n    if: github.actor == '"'"'dependabot[bot]'"'"'\n    runs-on: ubuntu-latest\n    steps:\n      - run: gh pr merge --auto --merge\n' \
    > "$full/.github/workflows/auto-merge.yml"
printf 'blank_issues_enabled: false\n' > "$full/.github/ISSUE_TEMPLATE/config.yml"
printf '## Checklist\n\n- [ ] Tests\n' > "$full/.github/PULL_REQUEST_TEMPLATE.md"
printf 'changelog:\n  exclude:\n    authors: [dependabot]\n  categories: []\n' > "$full/.github/release.yml"
run "$full"
expect_exit "complete directory passes" 0
expect_count "every section runs" "━━━" "$SECTIONS"
expect_count "no check fails" "✗" 0
expect_line "Dependabot grouping is recognised" "✓ Dependabot grouping enabled"
expect_line "auto-merge workflow is recognised" "✓ Auto-merge workflow configured for dependency bots"
expect_line "merge method of the workflow is reported" "Auto-merge workflow uses: --merge"
expect_line "PR template checklist is recognised" "✓ PR template has checklist items"

echo "git repository without origin remote"

gitrepo() { # gitrepo <dir> <default branch>
    cp -r "$full" "$1"
    git -C "$1" init -q
    git -C "$1" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$2"
}

gitrepo "$WORK/git-main" main
run "$WORK/git-main"
expect_exit "repository whose default branch is main passes" 0
expect_line "default branch main is recognised" "✓ Default branch is 'main'"
expect_line "GitHub API checks are skipped without a remote" "Skipping merge method compatibility check"

gitrepo "$WORK/git-master" master
run "$WORK/git-master"
expect_exit "repository whose default branch is master fails" 1
expect_line "default branch master is a failure" "✗ Default branch is 'master' (should be 'main')"
expect_count "every section runs" "━━━" "$SECTIONS"

echo "git repository with a non-GitHub origin remote"

gitrepo "$WORK/git-gitlab" main
git -C "$WORK/git-gitlab" remote add origin https://gitlab.com/acme/widget.git
mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\necho "{}"\n' "$WORK/gh-calls.log" > "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"
: > "$WORK/gh-calls.log"
PATH="$WORK/bin:$PATH" run "$WORK/git-gitlab"
expect_line "GitHub API checks are skipped for a non-GitHub remote" "Skipping merge method compatibility check"
calls=$(wc -l < "$WORK/gh-calls.log")
report "no gh call is made for a non-GitHub remote" "$([ "$calls" -eq 0 ] && echo 0 || echo 1)" "$calls gh call(s): $(tr '\n' ';' < "$WORK/gh-calls.log")"

echo "git repository with a github.com origin whose name contains a dot"

gitrepo "$WORK/git-dotted" main
git -C "$WORK/git-dotted" remote add origin https://github.com/netresearch/.github.git
: > "$WORK/gh-calls.log"
PATH="$WORK/bin:$PATH" run "$WORK/git-dotted"
expect_line "a dotted repository name yields its slug" "Checking GitHub settings for netresearch/.github"
calls=$(grep -c '^api repos/netresearch/\.github' "$WORK/gh-calls.log")
report "the API is queried with the dotted slug" "$([ "$calls" -gt 0 ] && echo 0 || echo 1)" "gh calls: $(tr '\n' ';' < "$WORK/gh-calls.log")"

echo
if [ "$fail" -ne 0 ]; then
    echo "verify-github-project.sh: FAILED ($count checks)"
    exit 1
fi
echo "verify-github-project.sh: all $count checks passed"
