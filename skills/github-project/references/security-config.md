# Security Configuration Reference

OpenSSF Scorecard optimization, CodeQL setup, merge strategy for signed commits, and solo maintainer auto-approve.

## OpenSSF Scorecard: Token-Permissions

The Scorecard Token-Permissions check flags any `write` permission declared at **workflow-level**. All `write` permissions MUST be at **job-level** only.

### Pattern: Workflow-level read, job-level write

```yaml
# CORRECT -- write at job level only
permissions:
    contents: read          # workflow-level: read only

jobs:
    release:
        permissions:
            contents: write  # job-level: narrowed to this job
        steps: ...

    read-only-job:
        permissions:
            contents: read   # job-level: explicit read
        steps: ...

# WRONG -- write at workflow level (Scorecard flags this)
permissions:
    contents: read
    pull-requests: write    # This fails Token-Permissions check!
```

### Common Workflows That Need Fixing

| Workflow | Typical violation | Fix |
|----------|-------------------|-----|
| `pr-quality.yml` | `pull-requests: write` at top | Move to auto-approve job only |
| `release-labeler.yml` | `issues: write, pull-requests: write` at top | Move to label-release job |
| `create-release.yml` | `contents: write` at top | Move to create-release job |

### SLSA Generator Pinning Exception

The `slsa-framework/slsa-github-generator` reusable workflow **cannot be SHA-pinned**. It requires `@vX.Y.Z` tag references because the slsa-verifier needs the tag to verify builder identity. This is tracked as [slsa-verifier#12](https://github.com/slsa-framework/slsa-verifier/issues/12). Accept this as an unavoidable Pinned-Dependencies gap.

## Branch-Protection for Scorecard (Solo Maintainer)

The Scorecard Branch-Protection check requires `required_approving_review_count >= 1`. For solo maintainer projects, combine with auto-approve:

```bash
# Set required_approving_review_count to 1 (auto-approve provides it)
gh api repos/OWNER/REPO/rulesets/RULESET_ID -X PUT --input - <<'EOF'
{
  "rules": [{
    "type": "pull_request",
    "parameters": {
      "required_approving_review_count": 1,
      "dismiss_stale_reviews_on_push": true
    }
  }]
}
EOF
```

This works because `pr-quality.yml` auto-approve provides the required approval via `github-actions[bot]`.

## Merge Strategy & Signed Commits

For signed commits workflow (rebase locally + merge commit):

| Repository Setting | Value | Why |
|--------------------|-------|-----|
| `allow_merge_commit` | **true** | Preserves signatures on feature branch commits |
| `allow_rebase_merge` | true | GitHub requires at least one of squash/rebase |
| `allow_squash_merge` | false | Destroys individual commit signatures |

| Branch Protection | Value | Why |
|-------------------|-------|-----|
| `required_signatures` | true | Enforces GPG/SSH signed commits |
| `required_linear_history` | **false** | Must be false - conflicts with merge commits |
| `required_conversation_resolution` | true | All review threads must be resolved before merge |

### Workflow

```bash
# 1. Developer rebases PR branch locally (signs commits)
git fetch origin && git rebase origin/main
git push --force-with-lease

# 2. Merge via merge commit (preserves signatures)
gh pr merge <number> --merge
```

### Auto-Merge Compatibility

| Merge Strategy | Works with `required_signatures`? |
|----------------|-----------------------------------|
| Merge commit | Yes - GitHub signs the merge commit |
| Rebase merge | No - GitHub cannot sign rewritten commits |
| Squash merge | No - GitHub cannot sign squashed commit |

**Important:** When enabling auto-merge, select "Create a merge commit" strategy.

For the full merge strategy guide, see `references/merge-strategy.md`.

## CodeQL Configuration

> **Deprecation:** CodeQL Action v3 will be deprecated in December 2026. Migrate all `github/codeql-action/*` references to v4. Check with:
> ```bash
> grep -r 'uses: github/codeql-action/' .github/workflows/ | grep -v '@v4'
> ```

Netresearch projects use custom CodeQL workflows (`.github/workflows/codeql.yml`). GitHub's "Default Setup" **MUST be disabled** -- they cannot coexist.

### The Problem

When both Default Setup and a custom workflow exist, CI fails with:
```
CodeQL analyses from advanced configurations cannot be processed when the default setup is enabled
```

### Required Action

**Before pushing a custom CodeQL workflow**, disable Default Setup:

```bash
# Check current state
gh api repos/OWNER/REPO/code-scanning/default-setup --jq '.state'

# Disable default setup (MANDATORY)
gh api repos/OWNER/REPO/code-scanning/default-setup -X PATCH -f state=not-configured
```

### Verification

```bash
gh api repos/OWNER/REPO/code-scanning/default-setup --jq 'if .state == "not-configured" then "OK: Default Setup disabled" else "FAIL: Default Setup still enabled - DISABLE IT" end'
```

## Required Reviews from All Requested Reviewers (MANDATORY)

PRs must **not be merged until all requested reviewers have submitted their review**. This includes human reviewers and automated reviewers (e.g., GitHub Copilot). Do not merge while any reviewer's status is still "PENDING".

> **Note:** GitHub branch protection only enforces a *minimum* approval count, not "all requested reviewers must respond." This rule is enforced as a **workflow policy** -- agents and humans must verify before merging.

### Check Reviewer Status Before Merging

```bash
# List all requested reviewers and their review state
gh pr view NUMBER --repo OWNER/REPO --json reviewRequests,reviews --jq '{
  pending: [.reviewRequests[].login],
  completed: [.reviews[] | {user: .author.login, state: .state}]
}'

# GraphQL: full reviewer status (requested + completed)
gh api graphql -f query='query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){pullRequest(number:$pr){
    reviewRequests(first:20){nodes{requestedReviewer{...on User{login}...on Bot{login}}}}
    reviews(last:20){nodes{author{login}state}}
  }}
}' -f owner=OWNER -f repo=REPO -F pr=NUMBER --jq '.data.repository.pullRequest | {
  awaiting: [.reviewRequests.nodes[].requestedReviewer.login],
  reviews: [.reviews.nodes[] | {user: .author.login, state: .state}]
}'
```

If `awaiting` is non-empty, the PR is **not ready to merge** -- those reviewers haven't responded yet.

## Required Conversation Resolution

All review threads on a PR **must be resolved** before merging:

```bash
# Enable
gh api repos/OWNER/REPO/branches/main/protection -X PUT \
  --input - << 'EOF'
{
  ...existing settings...,
  "required_conversation_resolution": true
}
EOF

# Verify
gh api repos/OWNER/REPO/branches/main/protection --jq 'if .required_conversation_resolution.enabled then "OK: Conversation resolution required" else "FAIL: Conversation resolution NOT required - ENABLE IT" end'

# List unresolved threads
gh api graphql -f query='query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){pullRequest(number:$pr){
    reviewThreads(first:50){nodes{id isResolved comments(first:1){nodes{body}}}}
  }}
}' -f owner=OWNER -f repo=REPO -F pr=NUMBER --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | {id, body: .comments.nodes[0].body}'

# Resolve a thread
gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -f id=THREAD_NODE_ID
```

## CI Annotations

CI checks can **PASS** while emitting warning annotations (e.g., actionlint/shellcheck via reviewdog, CodeQL deprecation notices). Always check before declaring a PR clean.

```bash
# Find check runs with annotations
gh api "repos/OWNER/REPO/commits/SHA/check-runs" \
  --jq '.check_runs[] | select(.output.annotations_count > 0) | {name: .name, id: .id, annotations: .output.annotations_count}'

# View specific annotations
gh api repos/OWNER/REPO/check-runs/CHECK_RUN_ID/annotations \
  --jq '.[] | {message, annotation_level, path, start_line}'
```

**Prevention:** Configure reviewdog actions with `fail_level: error` (not deprecated `fail_on_error` + `level`).

## PR Merge Checklist

| # | Prerequisite | How to check |
|---|-------------|--------------|
| 1 | All CI checks pass | `gh pr checks NUMBER` |
| 2 | No CI annotations | Check annotations via API (see above) |
| 3 | All requested reviewers responded | `gh pr view NUMBER --json reviewRequests` must be empty |
| 4 | All review threads resolved | GraphQL reviewThreads query |
| 5 | Branch rebased on target | `gh pr view NUMBER --json mergeStateStatus` is `CLEAN` |
