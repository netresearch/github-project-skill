# Merge Strategy for Signed Commits

This guide explains how to configure GitHub repositories that require both signed commits and clean git history.

## The Problem

GitHub's branch protection offers two relevant settings that conflict:

| Setting | Effect |
|---------|--------|
| `required_signatures` | All commits on protected branch must be signed |
| `required_linear_history` | Only squash or rebase merges allowed (no merge commits) |

**The conflict:** GitHub cannot sign commits during squash or rebase merge operations. When `required_linear_history` is enabled, GitHub rewrites commits server-side, but cannot sign them with your GPG/SSH key.

## The Solution

Use **local rebase + merge commit**:

1. Developers rebase their PR branch locally (signing commits with their key)
2. Force-push the rebased branch
3. Merge via merge commit (GitHub signs the merge commit with its key)

This gives you:
- ✅ Clean, linear history on feature branches
- ✅ Clear merge points on main branch
- ✅ All commits verified (developers sign feature commits, GitHub signs merge commits)

## Repository Settings

Configure via API:

```bash
gh api repos/{owner}/{repo} -X PATCH \
  -f allow_merge_commit=true \
  -f allow_rebase_merge=true \
  -f allow_squash_merge=false
```

| Setting | Value | Reason |
|---------|-------|--------|
| `allow_merge_commit` | `true` | Required for signed commits workflow |
| `allow_rebase_merge` | `true` | GitHub requires at least one of squash/rebase |
| `allow_squash_merge` | `false` | Destroys individual commit history and signatures |

**Note:** GitHub requires at least one of `allow_squash_merge` or `allow_rebase_merge` to be true. Keep `allow_rebase_merge` enabled but don't use it for PRs requiring signatures.

## Branch Protection Settings

Configure via API:

```bash
gh api repos/{owner}/{repo}/branches/main/protection -X PUT \
  --input - << 'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["ci"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "required_linear_history": false,
  "required_signatures": true,
  "required_conversation_resolution": true
}
EOF
```

| Setting | Value | Reason |
|---------|-------|--------|
| `required_signatures` | `true` | Enforces signed commits |
| `required_linear_history` | `false` | **Must be false** - blocks merge commits |
| `required_conversation_resolution` | `true` | All review threads must be resolved before merge |

## Developer Workflow

### Before Opening PR

```bash
# Ensure commits are signed
git config commit.gpgsign true
```

### Before Merging

```bash
# 1. Fetch latest main
git fetch origin

# 2. Rebase on main (re-signs commits)
git rebase origin/main

# 3. Force-push rebased branch
git push --force-with-lease
```

### Merging

```bash
# Use merge commit strategy
gh pr merge <number> --merge
```

## Auto-Merge Configuration

Auto-merge works with signed commits **only when using merge commit strategy**.

| Strategy | Compatible | Reason |
|----------|------------|--------|
| Merge commit | ✅ | GitHub signs merge commit with its key |
| Rebase | ❌ | GitHub cannot sign rewritten commits |
| Squash | ❌ | GitHub cannot sign squashed commit |

When configuring auto-merge workflows, ensure they use `--merge`:

```yaml
- name: Enable auto-merge
  run: gh pr merge --auto --merge "$PR_NUMBER"
```

## How GitHub Signing Works

When you merge via the GitHub UI or API with merge commit:

1. **Feature branch commits**: Retain original GPG/SSH signatures from developers
2. **Merge commit**: Signed by GitHub's web-flow key (`noreply@github.com`)

Both are marked as "Verified" in the GitHub UI:
- Developer commits show the developer's GPG key
- Merge commits show "Verified" with GitHub as the signer

## Troubleshooting

### "Merge commits are not allowed on this repository"

**Cause:** `allow_merge_commit` is false in repository settings.

**Fix:**
```bash
gh api repos/{owner}/{repo} -X PATCH -f allow_merge_commit=true
```

### "Base branch requires signed commits. Rebase merges cannot be automatically signed"

**Cause:** `required_linear_history` is true, forcing rebase merge which GitHub cannot sign.

**Fix:**
```bash
gh api repos/{owner}/{repo}/branches/main/protection -X PUT \
  --input - << 'EOF'
{
  ...existing settings...,
  "required_linear_history": false
}
EOF
```

### Auto-merge fails with signature error

**Cause:** Auto-merge configured with rebase or squash strategy.

**Fix:** Update auto-merge workflow to use `--merge` flag instead of `--rebase` or `--squash`.

### Rulesets cannot block merge on a pending review

Neither branch protection nor rulesets support "block merge while any requested reviewer hasn't submitted yet". The options available are adjacent but not equivalent:

| Setting | What it does | Not what you want |
|---|---|---|
| `required_approving_review_count: 1` | Needs **one approval** | Doesn't wait for other requested reviewers |
| `required_review_thread_resolution: true` | Blocks on **unresolved threads** | Doesn't block before any thread is created |

If you need to hold merge until Copilot (or any other requested reviewer) has actually posted its review, the workaround is a custom GitHub Actions status check that queries pending reviewers and fails if any are outstanding — then require that check in branch protection.

```bash
# Example: fail the check if any reviewer — user or team — is still requested.
pending=$(gh api "repos/$REPO/pulls/$PR" \
  --jq '((.requested_reviewers // []) | length) + ((.requested_teams // []) | length)')
if [[ "$pending" -gt 0 ]]; then
  echo "::error::Still waiting on $pending review request(s) (user/team)"
  exit 1
fi
```

## References

- [GitHub Branch Protection](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches)
- [Signing Commits](https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-commits)
- [About Merge Methods](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/about-merge-methods-on-github)
