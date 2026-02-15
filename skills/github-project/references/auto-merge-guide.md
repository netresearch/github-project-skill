# Auto-merge Troubleshooting Guide

Quick reference for diagnosing and fixing auto-merge issues with Dependabot and Renovate.

## Troubleshooting Quick Reference

| Symptom | Cause | Fix |
|---------|-------|-----|
| PR BLOCKED, checks pass | Check names don't match | Update branch protection to use exact names (e.g., `job (variant)` not `job`) |
| PR BLOCKED, `reviewDecision: REVIEW_REQUIRED` | `require_code_owner_reviews: true` | Disable code owner reviews or add code owner approval |
| PR BLOCKED, unresolved threads | `required_conversation_resolution: true` | Resolve all review threads before merging |
| PR has pending reviewers | Requested reviewers haven't responded | Wait for all requested reviewers to submit their review |
| Renovate PR not using bypass | Workflow racing with Renovate | Only approve in workflow; let Renovate enable auto-merge via `platformAutomerge` |
| CI can't push to main | Branch protection blocks direct push | Use Renovate `lockFileMaintenance` instead |
| Workflow not triggering | Rapid merges skip push events | Add `workflow_dispatch` trigger, run manually |
| "Merge method X not allowed" | Wrong merge strategy | Check `gh api repos/O/R --jq '{merge: .allow_merge_commit, squash: .allow_squash_merge, rebase: .allow_rebase_merge}'`; match workflow |
| Bot detection misses reruns | `github.actor` changes on synchronize | Use `github.event.pull_request.user.login` instead of `github.actor` |
| Gitleaks fails on bot PRs | `GITLEAKS_LICENSE` secret unavailable | Skip gitleaks for bot PRs or use `.gitleaks.toml` allowlist |
| Old PRs not auto-merging | Opened before workflow existed | Comment `@dependabot rebase` / `@renovate rebase` to trigger `synchronize` |
| Can't merge workflow file PRs | `GITHUB_TOKEN` lacks `workflows` scope | Merge manually; use workflow check in `auto-merge-direct.yml` template |
| Auto-approve skipped, PR stuck `REVIEW_REQUIRED` | Auto-approve raced with Copilot reviewer | Re-run the auto-approve workflow after Copilot finishes (see below) |

## Auto-Approve Race Condition with Copilot Reviewer

When using a solo-maintainer auto-approve workflow alongside GitHub Copilot as a reviewer, a race condition can leave PRs stuck in `REVIEW_REQUIRED`:

1. New push triggers both auto-approve workflow and Copilot review
2. Auto-approve runs first, sees Copilot as a pending reviewer, skips approval
3. Stale review dismissal clears any previous approvals from the push
4. Copilot finishes reviewing (state: `COMMENTED`) but doesn't approve
5. No approval exists, PR is `BLOCKED`

**Symptoms:** `mergeStateStatus: BLOCKED`, `reviewDecision: REVIEW_REQUIRED`, auto-approve step shows "skipped", `reviewRequests` is empty.

**Fix:** Re-run the auto-approve workflow after Copilot finishes:

```bash
# Find the workflow run ID
gh api "repos/OWNER/REPO/actions/runs?per_page=5" \
  --jq '.workflow_runs[] | select(.name == "YOUR_WORKFLOW_NAME") | {id, head_sha: .head_sha[:7]}'

# Re-run it
gh api repos/OWNER/REPO/actions/runs/RUN_ID/rerun -X POST
```

## Recommended Renovate Config for Auto-merge

```json
{
  "extends": ["config:recommended"],
  "automergeType": "pr",
  "platformAutomerge": true,
  "lockFileMaintenance": {
    "enabled": true,
    "schedule": ["before 6am on monday"]
  },
  "packageRules": [
    {
      "matchUpdateTypes": ["patch", "minor", "pin", "digest"],
      "automerge": true
    }
  ]
}
```

**Key settings:**
- `platformAutomerge: true` - Renovate enables auto-merge (uses bypass permissions)
- `lockFileMaintenance` - Handles lock file updates via PR (not direct push)

## Branch Protection for Auto-merge

```bash
# Check required checks vs actual check names
gh api repos/OWNER/REPO/branches/main/protection/required_status_checks --jq '.checks[].context'

# Check code owner requirement (should be false for auto-merge)
gh api repos/OWNER/REPO/branches/main/protection/required_pull_request_reviews --jq '.require_code_owner_reviews'

# Check bypass apps
gh api repos/OWNER/REPO/branches/main/protection/required_pull_request_reviews --jq '.bypass_pull_request_allowances.apps[].slug'

# Fix: Disable code owner reviews, add bypass apps
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
