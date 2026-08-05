# gh CLI Commands Reference

Non-obvious `gh` CLI gotchas and troubleshooting patterns for GitHub repository management. For basic `gh pr`/`gh run`/`gh api` usage, `gh help` and `gh <command> --help` cover it.

## Packages (GHCR)

```bash
# List org container packages
gh api "orgs/ORG/packages?package_type=container"

# Inspect a package (needs read:packages)
gh api "orgs/ORG/packages/container/PACKAGE"

# Delete a package — needs BOTH read:packages AND delete:packages.
# admin:org alone is NOT enough; delete:packages alone still 403s.
gh auth refresh -h github.com -s read:packages,delete:packages
gh api -X DELETE "orgs/ORG/packages/container/PACKAGE"   # 204; GET then 404
```

Verify the token's effective scopes from GitHub's response header, not `gh auth status` (which can lag):

```bash
gh api "" --include 2>&1 | grep -i '^X-Oauth-Scopes:'
```

### GHCR cleanup can brick every tag of a multi-arch image

`actions/delete-package-versions` with `delete-only-untagged-versions: true` is NOT manifest-list aware: for a multi-arch image the per-arch child manifests and the cosign/SLSA referrers are stored as separate UNTAGGED versions — the cleanup deletes them and every tagged index then points at missing children (`docker pull` fails with manifest errors). Cleanup for multi-arch GHCR images must resolve which untagged digests are referenced by tagged indexes/referrers and keep them.

### Contents/Git-Data API commits are unsigned and carry no sign-off

A `PUT /repos/…/contents/…` commit is created server-side — `-S` and `--signoff` never apply, so it lands `verified: false` without a DCO trailer, and an archived repo makes it unfixable. When commits must be signed/signed-off (always, per policy): clone and commit locally; land signed commits BEFORE archiving.


## Common Troubleshooting Patterns

### Wait for CI with the native watcher, not a hand-rolled loop

To wait for PR checks, run `gh pr checks NUMBER --repo OWNER/REPO --watch [--fail-fast]` (or `gh run watch RUN_ID` for a specific run) as a background command — do **not** hand-write a `jq` poll loop. The native watcher already handles pending-state representation, new-check appearance, and refresh; hand-rolled loops re-derive those semantics from undocumented field shapes (`conclusion` may be `""`, `null`, or absent while a check is running) and reliably get them wrong.

Three recurring bugs in ad-hoc watchers:

- An empty-string `conclusion` not matched by the "pending" filter → false "all checks done".
- A bare `pending -eq 0 && break` snapshot, which is true both **before** runs register and **after** they finish. Run immediately after a push (or a close/reopen), it reads "0 pending" before the freshly-triggered run has appeared → false "all green" → premature merge.
- A wrong `createdAt` cutoff that skips the actual run → false timeout.

`gh pr checks` exits non-zero when checks fail — gate on the exit code. If you must hand-roll (watching something `gh` has no watcher for), gate on a **named required check reaching a terminal pass/fail state**, never on a 0-pending count. After pushing, capture the new SHA and confirm `headRefOid` matches before trusting any watch.

### `gh run rerun` re-runs the OLD state — only for genuine flakes

`gh run rerun [--failed]` reuses the original `GITHUB_SHA`/`GITHUB_REF` recorded at run-creation time. Two consequences:

- For `pull_request` workflows that SHA is the **merge commit** computed when the run was first created, so a rerun still tests the PR against the **old base**. After fixing a base-branch breakage, a rerun reproduces the old failure. To pick up new base state, create a new event: rebase the PR branch onto the fixed base and push (an empty commit works). (Reusable-workflow `@ref` resolution is also pinned at run-creation — see `reusable-workflow-pitfalls.md`.)
- Reruns are correct only for genuinely transient infra failures where the same code state should pass: runner/network blips, partial codecov uploads, registry pull flakes (e.g. `Get "https://registry-1.docker.io/v2/": context deadline exceeded`), Sigstore/Rekor 409s. Don't debug the workflow for those — just `gh run rerun --failed`.

### A Copilot review request can evaporate — verify after requesting

`POST …/requested_reviewers` for `copilot-pull-request-reviewer[bot]` returns success, but the request can silently vanish without a review ever landing: `reviewRequests` comes back `[]` and `latestReviews` stays empty on the head. Observed after a force-push replaced the head shortly after the request. After requesting, verify (`gh pr view N --json reviewRequests,latestReviews`); if both are empty a few minutes later, re-request once — the second request reliably sticks.

### `gh pr view --json merged` is not a field

The rollup field is `mergedAt` (null while open) — or ask `state` (`MERGED`/`OPEN`/`CLOSED`). `--json merged` errors "Unknown JSON field"; GraphQL (`pullRequest.merged`) does have the boolean.

### Rapid `gh api` calls intermittently return HTTP 401

Rapid sequences of `gh api` calls (REST + GraphQL) sometimes return `401 "Requires authentication"` even with valid auth — transient, clears with ~5-10s spacing and a retry. **Trap:** piping a `gh` listing straight into `while read` consumes the 401 error text as data when a call fails (e.g. JSON error braces get fed into a GraphQL mutation as "thread IDs"). Always capture output into a variable first, check the exit status, then iterate; add a `sleep 5-10` between bulk review-thread replies/resolves.

### Reading a run's log: grep the error text, not the status code

`gh run view --job=<id> --log` prefixes every line with the step name. Three traps when you read errors in it:

- **`--log-failed | tail` shows the wrong end of the log.** On a repo running `step-security/harden-runner`, the post-job step appends its egress-audit dump — DNS resolutions, `sudo` calls, the full `agent.service` journal — *after* the step that failed. Tailing a failed job therefore returns pages of runner telemetry and none of the error. Redirect to a file and grep for the annotation marker instead:
  ```bash
  gh run view <RUN_ID> --repo OWNER/REPO --log-failed > run.log
  grep -nE '##\[error\]' run.log      # then read the ~20 lines above each hit
  ```
  The lines above the marker carry the actual cause (the failing command's own output); the marker line itself is often just `Process completed with exit code 1`.

- **A bare status code matches things that are not errors.** `grep -c 403` over a job log also hits commit SHAs, ref names and git plumbing output in the `Checkout` step. A real case: a fixed run still showed 8 hits for `403` — all from `Checkout`, none an API error — which reads as "still broken". Match the error *text* (`Client Error: Forbidden`), and scope the count to the step that makes the calls.

  Each line is `<job>\t<step>\t<timestamp> <text>`, so anchor the step to the start of the line — an unanchored step name also matches log *prose* that mentions it:
  ```bash
  gh run view --job="$JOB" --log > job.log
  grep -c 'Client Error: Forbidden' job.log                  # not: grep -c 403
  grep -cP '^check-stars\tCheck for new stars\t.*403' job.log  # scoped to the step
  ```
- **Count what failed, not what succeeded.** A step can print `Found: 0 items` because there is nothing new *or* because every fetch failed. Those are the same line. Assert on the failure count (`grep -c 'Failed to get'`) before reading a zero as good news.

### Python steps: timestamps are flush times, not print times

The log's per-line timestamps come from when the runner *received* the line. Python block-buffers stdout when it is not a TTY, so a whole run's output arrives in one flush and every line carries the same timestamp — 1670 lines sharing one second is normal, not a hang. Any timing analysis ("it broke 19 minutes in") read off those timestamps is invalid.

Set `PYTHONUNBUFFERED: 1` in the step's `env:` (or run `python -u`) when you need per-line timing. Node, Go and shell are line-buffered to a pipe and do not need this.

### PR/issue body prose: one line per paragraph

In PR/issue **bodies and comments**, GitHub's renderer turns a single newline into a hard line break (`<br>`) — it enables hard line breaks for issue/PR/comment text, unlike the CommonMark default (where a single newline is a soft break and an intentional break needs two trailing spaces, a trailing `\`, or an explicit `<br>`). So a prose paragraph hard-wrapped at ~80 columns renders as jagged, mid-sentence lines. Write each prose paragraph as one continuous line and separate paragraphs with a blank line; keep line breaks only where the break is the content (inside fenced code blocks, one item per line in a list). Source files behave the other way — reStructuredText and CommonMark `.md` render a single newline as a *soft* break, and a commit-message body is plain text, so all three are conventionally wrapped at ~72–80 columns and the wrap never shows. The rule follows how the destination treats a single newline, not whether the text is Markdown. When generating a body with `gh pr create --body-file` / `gh issue create --body-file`, do not pipe it through a hard-wrapper.

### Escape every `@`-token — GitHub mentions are live

Any raw `@something` in interactive GitHub surfaces (PR/issue/discussion bodies and comments, release notes) is parsed as a user mention and — when it resolves to an existing user or team — can notify that account — `@main` in a workflow-pinning discussion repeatedly pinged the real GitHub user named "main". Repository docs (README, wiki) render the link but generally do not notify. Wrap every non-mention `@`-token in backticks (`` `@main` ``) or escape it (`\@main`) before posting; audit generated bodies for bare `@` before sending.

### Add an image to an issue or PR (no browser needed)

GitHub's native attachment uploader (`user-attachments/assets/…`) needs a browser session + CSRF and cannot be driven by `gh`/the API — but that does **not** mean images are impossible. Commit the PNGs to a dedicated branch (in a fork if you lack push to the target), then embed the raw URL in the body/comment:

```bash
git push fork HEAD:issue-NNNN-screenshots
# In the issue/PR body:
# ![before](https://raw.githubusercontent.com/USER/REPO/BRANCH/before.png)
```

`raw.githubusercontent.com` serves `image/png` and GitHub renders it inline. Generate the image first; for a JS-populated widget, point the page at a local copy of the real data and screenshot the rendered result.

To **replace** an already-embedded image, do not overwrite the file under the same path — publish under a new filename and point the body at it. Images on `raw.githubusercontent.com` are served directly from GitHub's own domain (not through the camo proxy, which only fronts external images), behind a CDN with a short cache lifetime — so after you replace the file, a branch-based raw URL can keep returning the old bytes until the cache expires, and a `?v=` query is not a reliable bust. A new filename is a fresh path the CDN has not cached, so it loads immediately. Confirm the new raw URL serves the new file (`curl -fsSL RAW_URL | sha256sum`, compare to the local file — `-f` fails on HTTP errors so you don't hash a 404 page) before editing the body.

### Debug Auto-merge Pipeline

```bash
# 1. Check PR status
gh pr view NUMBER --repo OWNER/REPO --json mergeStateStatus,reviewDecision,autoMergeRequest

# 2. Check actual vs required checks
echo "=== Required checks ===" && \
gh api repos/OWNER/REPO/branches/main/protection/required_status_checks --jq '.checks[].context' && \
echo "=== Actual checks ===" && \
gh api graphql -f query='query{repository(owner:"OWNER",name:"REPO"){
  pullRequest(number:NUMBER){commits(last:1){nodes{commit{
    statusCheckRollup{contexts(first:30){nodes{...on CheckRun{name conclusion}}}}
  }}}}
}}' --jq '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[].name'

# 3. Check bypass permissions
gh api repos/OWNER/REPO/branches/main/protection/required_pull_request_reviews \
  --jq '{code_owner: .require_code_owner_reviews, bypass: .bypass_pull_request_allowances.apps[].slug}'

# 4. Check if branch is behind
gh api graphql -f query='query{repository(owner:"OWNER",name:"REPO"){
  pullRequest(number:NUMBER){mergeStateStatus}
}}' --jq '.data.repository.pullRequest.mergeStateStatus'
```

### Fix Stale Merge Base on Fork PRs

When a fork's `main` is behind upstream and a PR is created after syncing, GitHub may cache the old merge base. The PR shows too many commits (e.g., N+1 instead of 1). Neither `update-branch` API nor force-pushing fixes it because the SHA hasn't changed.

```bash
# Close and reopen the PR to force merge base recalculation
gh pr close NUMBER --repo OWNER/REPO && sleep 2 && gh pr reopen NUMBER --repo OWNER/REPO
```

### Inline `--body` with Backticks EXECUTES Them — Always `--body-file`

An inline body in double quotes — `gh pr create --body "..."` with a Markdown code span inside — makes bash run the span's **unescaped** backtick contents as command substitution before `gh` ever sees the text (escaped backticks or a single-quoted body stay literal — but bodies are routinely assembled unescaped). In one real session this executed `bun audit`, `npm login`, and `npm publish` (only an ENEEDAUTH failure prevented an actual publish), and the resulting bodies were garbled with the substituted output. Any double-quoted body whose code spans are not escaped will misfire.

```bash
# WRONG: unescaped backticks execute npm test, $ expands
gh pr create --body "Run `npm test` first"

# RIGHT: quoted heredoc (no expansion) + --body-file
cat > /tmp/body.md <<'EOF'
Run `npm test` first
EOF
gh pr create --body-file /tmp/body.md
```

Applies equally to `gh issue create/comment`, `gh release create --notes`, `gh pr comment`, and `git commit -m` with backticks (`-F file` there). Verify the posted body afterward (`gh pr view N --json body`) — garbling is silent.

### GraphQL with Special Characters (--input pattern)

When GraphQL variables contain backticks, dollar signs, or other characters that cause bash escaping issues, pipe JSON via `--input -`:

```bash
# PROBLEM: Backticks and $ in body cause bash escaping errors
gh api graphql -f query='mutation($body: String!) { ... }' -f body='Fixed `@rollup/plugin-terser`'
# Error: Expected VAR_SIGN, actual: UNKNOWN_CHAR

# SOLUTION: Use --input with stdin
cat << 'ENDJSON' | gh api graphql --input -
{
  "query": "mutation($body: String!, $threadId: ID!) { addPullRequestReviewThreadReply(input: {body: $body, pullRequestReviewThreadId: $threadId}) { comment { id } } }",
  "variables": {
    "body": "Fixed `@rollup/plugin-terser` in `dependencies`.",
    "threadId": "PRRT_kwDOxxxxxx"
  }
}
ENDJSON
```

This pattern is especially useful when:
- Replying to PR review threads with markdown formatting
- Any GraphQL mutation where the body contains code references
- Variables contain characters that interact with bash quoting (`$`, `` ` ``, `!`, `\`)

### Fix Common Issues

```bash
# Fix: Update check names in branch protection
gh api repos/OWNER/REPO/branches/main/protection/required_status_checks -X PATCH \
  -f strict=true \
  --input - << 'EOF'
{"checks": [{"context": "job-name (variant)"}]}
EOF

# Fix: Disable code owner reviews blocking auto-merge
gh api repos/OWNER/REPO/branches/main/protection/required_pull_request_reviews -X PATCH \
  -f require_code_owner_reviews=false

# Fix: Add bypass apps
gh api repos/OWNER/REPO/branches/main/protection/required_pull_request_reviews -X PATCH \
  --input - << 'EOF'
{"bypass_pull_request_allowances": {"apps": ["dependabot", "renovate"]}}
EOF
```

## Rate Limits — GITHUB_TOKEN in Actions

The `GITHUB_TOKEN` (installation token) that Actions injects is **not** billed
against your user quota. It has its own, much tighter cap:

- **1,000 REST requests per hour**, charged to the token issued for the
  **repository whose workflow is running** — and shared across *every* call that
  token makes, **including calls to other repositories**. Calling 100 repos from
  one workflow does not give you 100 separate budgets; it draws down the one
  workflow-repo budget. (Separate from the 5,000/hr user limit and the GraphQL
  point budget.)

A workflow that probes many paths across many repos exhausts this fast — e.g. a
collector doing ~15 per-file `contents` calls across ~100 repos ≈ 1,500 calls in
one run, all against the single workflow-repo budget.

**Symptom that misleads:** the `build` job succeeds while the `deploy` /
`deploy-pages` job fails with a 403 — the same exhausted token 403s the Pages
deployment API call, so it reads like a Pages/deploy bug rather than a
rate-limit one.

**Fix — one recursive git-tree call instead of N per-file probes.** To test which
files exist in a repo, fetch the whole tree once and check paths in memory. The
trees endpoint resolves a ref (branch name or SHA) directly, so this is genuinely
one call per repo:

```bash
# One call lists every path at a ref (recursive), vs one call per file
gh api "repos/OWNER/REPO/git/trees/main?recursive=1" \
  --jq '.tree[]? | select(.type == "blob") | .path'
# then: does "SECURITY.md" appear? -> no extra request
```

This drops a ~100-repo sweep from ~1,500 calls to a few hundred (one tree call
per repo) and keeps a nightly Pages build well under the cap.

**Before a long collector loop,** check headroom (the `rate_limit` endpoint does
NOT count against the quota):

```bash
gh api rate_limit --jq '(.resources.core? // empty) | {remaining, reset}'
```
