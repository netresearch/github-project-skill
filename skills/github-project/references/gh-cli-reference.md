# gh CLI Commands Reference

Essential `gh` CLI commands for GitHub repository management.

## Repository Information

```bash
# Get repo info
gh repo view OWNER/REPO --json name,defaultBranchRef,description

# List branches
gh api repos/OWNER/REPO/branches --jq '.[].name'

# Get branch protection rules
gh api repos/OWNER/REPO/branches/main/protection
```

## Pull Requests

```bash
# List PRs
gh pr list --repo OWNER/REPO --state open

# View PR details
gh pr view NUMBER --repo OWNER/REPO --json state,mergeStateStatus,reviewDecision,autoMergeRequest

# Check PR merge status (GraphQL - more detailed)
gh api graphql -f query='query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){pullRequest(number:$pr){
    state mergeStateStatus reviewDecision mergeable
    autoMergeRequest{enabledBy{login}mergeMethod}
    commits(last:1){nodes{commit{statusCheckRollup{state}}}}
  }}
}' -f owner=OWNER -f repo=REPO -F pr=NUMBER

# Approve PR
gh pr review NUMBER --repo OWNER/REPO --approve

# Enable auto-merge
gh pr merge NUMBER --repo OWNER/REPO --auto --merge

# Merge PR directly
gh pr merge NUMBER --repo OWNER/REPO --merge  # or --squash, --rebase

# Wait for PR CI to finish — use the native watcher, NOT a hand-rolled poll loop
gh pr checks NUMBER --repo OWNER/REPO --watch --fail-fast

# Comment on PR
gh pr comment NUMBER --repo OWNER/REPO --body "message"

# Trigger bot rebase
gh pr comment NUMBER --repo OWNER/REPO --body "@dependabot rebase"
gh pr comment NUMBER --repo OWNER/REPO --body "@renovate rebase"
```

## Branch Protection

```bash
# Get full branch protection
gh api repos/OWNER/REPO/branches/main/protection

# Get required status checks
gh api repos/OWNER/REPO/branches/main/protection/required_status_checks

# Update required status checks
gh api repos/OWNER/REPO/branches/main/protection/required_status_checks -X PATCH \
  --input - << 'EOF'
{
  "strict": true,
  "checks": [
    {"context": "lint"},
    {"context": "build"},
    {"context": "test"}
  ]
}
EOF

# Get/update PR review requirements
gh api repos/OWNER/REPO/branches/main/protection/required_pull_request_reviews

# Disable code owner reviews, add bypass apps
gh api repos/OWNER/REPO/branches/main/protection/required_pull_request_reviews -X PATCH \
  --input - << 'EOF'
{
  "require_code_owner_reviews": false,
  "required_approving_review_count": 1,
  "bypass_pull_request_allowances": {
    "apps": ["dependabot", "renovate"]
  }
}
EOF
```

## GitHub Actions

```bash
# List workflow runs
gh run list --repo OWNER/REPO --limit 10

# List runs for specific workflow
gh run list --repo OWNER/REPO --workflow=build.yml

# View run details
gh run view RUN_ID --repo OWNER/REPO

# View failed logs
gh run view RUN_ID --repo OWNER/REPO --log-failed

# Re-run failed jobs (genuine flakes only — see caveat below)
gh run rerun RUN_ID --repo OWNER/REPO --failed

# Wait for a workflow run to finish (native watcher, prefer over hand-rolled loops)
gh run watch RUN_ID --repo OWNER/REPO

# Manually trigger workflow
gh workflow run WORKFLOW.yml --repo OWNER/REPO --ref main

# List workflows
gh workflow list --repo OWNER/REPO
```

## Releases and Tags

```bash
# List releases
gh release list --repo OWNER/REPO

# Create release (after pushing signed tag)
git tag -s vX.Y.Z -m "vX.Y.Z"
git push origin vX.Y.Z
gh release create vX.Y.Z --repo OWNER/REPO --title "vX.Y.Z" --notes "Release notes"

# Get latest release
gh release view --repo OWNER/REPO

# Download release assets
gh release download TAG --repo OWNER/REPO
```

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

## Files and Content

```bash
# Get file contents (base64 encoded)
gh api repos/OWNER/REPO/contents/PATH --jq '.content' | base64 -d

# Update file via API
gh api repos/OWNER/REPO/contents/PATH -X PUT \
  -f message="commit message" \
  -f content="$(base64 -w0 < file)" \
  -f sha="$(gh api repos/OWNER/REPO/contents/PATH --jq '.sha')"
```

## Repository Settings

```bash
# Update repo settings
gh repo edit OWNER/REPO --enable-projects --enable-wiki=false

# Set topics
gh api repos/OWNER/REPO/topics -X PUT -f names='["topic1","topic2"]'

# Update description
gh repo edit OWNER/REPO --description "New description"
```

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

### Rapid `gh api` calls intermittently return HTTP 401

Rapid sequences of `gh api` calls (REST + GraphQL) sometimes return `401 "Requires authentication"` even with valid auth — transient, clears with ~5-10s spacing and a retry. **Trap:** piping a `gh` listing straight into `while read` consumes the 401 error text as data when a call fails (e.g. JSON error braces get fed into a GraphQL mutation as "thread IDs"). Always capture output into a variable first, check the exit status, then iterate; add a `sleep 5-10` between bulk review-thread replies/resolves.

### PR/issue body prose: one line per paragraph

In PR/issue **bodies and comments**, GitHub's renderer turns a single newline into a hard line break (`<br>`) — it enables hard line breaks for issue/PR/comment text, unlike the CommonMark default (where a single newline is a soft break and an intentional break needs two trailing spaces, a trailing `\`, or an explicit `<br>`). So a prose paragraph hard-wrapped at ~80 columns renders as jagged, mid-sentence lines. Write each prose paragraph as one continuous line and separate paragraphs with a blank line; keep line breaks only where the break is the content (inside fenced code blocks, one item per line in a list). Source files behave the other way — reStructuredText and CommonMark `.md` render a single newline as a *soft* break, and a commit-message body is plain text, so all three are conventionally wrapped at ~72–80 columns and the wrap never shows. The rule follows how the destination treats a single newline, not whether the text is Markdown. When generating a body with `gh pr create --body-file` / `gh issue create --body-file`, do not pipe it through a hard-wrapper.

### Add an image to an issue or PR (no browser needed)

GitHub's native attachment uploader (`user-attachments/assets/…`) needs a browser session + CSRF and cannot be driven by `gh`/the API — but that does **not** mean images are impossible. Commit the PNGs to a dedicated branch (in a fork if you lack push to the target), then embed the raw URL in the body/comment:

```bash
git push fork HEAD:issue-NNNN-screenshots
# In the issue/PR body:
# ![before](https://raw.githubusercontent.com/USER/REPO/BRANCH/before.png)
```

`raw.githubusercontent.com` serves `image/png` and GitHub renders it inline via camo. Generate the image first; for a JS-populated widget, point the page at a local copy of the real data and screenshot the rendered result.

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
