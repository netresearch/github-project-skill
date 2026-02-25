# PR Shows Too Many Commits (Stale Merge Base on Forks)

When a fork's `main` is behind upstream and you create a PR after syncing, GitHub may cache the old merge base and show too many commits (e.g., 38 commits when only 1 is new). The `update-branch` API returns "There are no new commits on the base branch" and force-pushing says "Everything up-to-date" since the SHA hasn't changed.

## Steps to Reproduce

1. Fork is behind upstream by N commits
2. Create feature branch from upstream main
3. Push fork main to catch up
4. PR still shows N+1 commits instead of 1

## Fix

Close and reopen the PR to force GitHub to recalculate the merge base:

```bash
gh pr close NUMBER --repo OWNER/REPO && sleep 2 && gh pr reopen NUMBER --repo OWNER/REPO
```

This forces GitHub to re-evaluate the common ancestor between your branch and the target branch.

## Why This Happens

GitHub computes the merge base (common ancestor) when the PR is created and caches it. If the fork's default branch is later updated (synced with upstream), the cached merge base is not recalculated automatically. The close/reopen cycle invalidates the cache and triggers fresh merge-base computation.

## Alternative Approaches

If close/reopen doesn't work:

1. **Create a new PR:** Push the same branch and create a fresh PR
2. **Rebase onto upstream:** `git rebase upstream/main && git push --force-with-lease`
3. **Update fork first:** Sync fork's main before creating the feature branch
