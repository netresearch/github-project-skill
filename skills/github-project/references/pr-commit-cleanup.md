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

## Never reset a PR's head branch to its base commit

Force-updating an open PR's head ref so it momentarily points at the base branch's commit (zero diff vs. base) causes GitHub to **auto-close the PR**. Reopening then fails ("Could not open the pull request") and you must open a fresh PR.

This bites when replacing a PR's commits (e.g. to re-sign unsigned ones): patching the branch ref back to base before re-committing produces the zero-diff state. Instead, build the replacement commits on top of base **locally** and force-push in one step, so the branch always has ≥1 commit ahead of base:

```bash
git reset --soft origin/main   # keep the working tree; do NOT push this state
git commit -s -m "…"           # rebuild the commit(s)
git push --force-with-lease    # branch is never momentarily zero-diff on the remote
```

If a PR does get auto-closed this way, just open a new PR from the (now-correct) branch rather than fighting reopen.
