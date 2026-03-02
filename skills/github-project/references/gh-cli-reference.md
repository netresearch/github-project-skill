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

# Re-run failed jobs
gh run rerun RUN_ID --repo OWNER/REPO --failed

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
