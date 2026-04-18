# Multi-Repo Operations

Batch and fleet-wide operations — releases, rebases, lint fixes, config rollouts — across many repositories in one sweep.

## Hard Rule: Dry-Run Before Any >3-Repo Operation

Batch ops amplify small mistakes linearly. A version-bump ordering bug that affects 1 repo is a nuisance; across 30 repos it's 30 broken release workflows. Before executing on more than 3 repos, produce a dry-run manifest and get explicit approval.

### Dry-run manifest format

Emit a table — one row per repo, one column per step. Do not execute until the user approves the plan.

| Repo | Precondition | Action | Postcondition |
|------|--------------|--------|---------------|
| owner/repo-a | main clean, CI green | bump plugin.json 1.2.3 → 1.2.4, open PR | PR URL, auto-merge enabled |
| owner/repo-b | main clean, CI green | bump plugin.json 1.2.3 → 1.2.4, open PR | PR URL, auto-merge enabled |

Columns must be concrete — exact commands, exact file paths, exact version strings. A plan that says "update version" is not a plan; it's an intention.

### Approval prompt template

```
I'll now execute the above plan across N repos. Proceed? (reply "go" to execute, or
name specific repos to skip.)
```

Wait for "go" (or an equivalent affirmative). Silence is not approval.

## Parallel PR Rebasing

For N PRs that need rebasing on their default branches, dispatch parallel subagents — one per PR — with failure isolation.

```bash
# 1. Enumerate open PRs needing rebase
gh pr list --state open --json number,headRefName,baseRefName,mergeStateStatus \
  --jq '.[] | select(.mergeStateStatus == "BEHIND" or .mergeStateStatus == "DIRTY")'
```

### Parallel-agent prompt skeleton

For each PR, spawn a subagent with this task (run them in one message for concurrency):

```
PR #<NUM> on <owner/repo>:
1. Checkout the PR branch in a fresh worktree
2. Rebase onto origin/<base-branch>
3. If conflicts: do NOT resolve speculatively — abort the rebase, report the files
4. If clean: force-push with --force-with-lease
5. Re-check PR status; report "rebased" or "conflicts: <files>"
```

### Failure isolation

One bad rebase must not block the rest. Structure the supervisor prompt so each PR reports independently. Collect results into a summary table:

| PR | Status | Note |
|----|--------|------|
| #101 | rebased | clean |
| #102 | conflicts | internal/server/handler.go |
| #103 | rebased | clean |

Then address conflicts one by one — never batch-resolve.

## Multi-Repo Release Orchestration

The canonical order is: **version-bump PR merged → tag pushed**, never the reverse. Tag-before-bump causes Release workflows to run against the wrong version and fail.

### Pre-flight validation (per repo)

Before touching any repo, validate:

- `plugin.json.version` / `composer.json.version` / `package.json.version` parity against each other
- Current git tag on default branch is not already the target version
- CI on default branch is green
- No pending version-bump PR already open

```bash
# Example parity check for a skill repo
VERSION_PLUGIN=$(jq -r '.version' plugin.json)
VERSION_SKILL=$(awk '/^version:/ {print $2}' skills/*/SKILL.md | tr -d '"')
VERSION_COMPOSER=$(jq -r '.version // empty' composer.json)

if [[ "$VERSION_PLUGIN" != "$VERSION_SKILL" ]]; then
  echo "VERSION MISMATCH: plugin.json=$VERSION_PLUGIN SKILL.md=$VERSION_SKILL"
  exit 1
fi
```

### Release sequence (per repo)

1. Open version-bump PR → wait for CI green and review
2. Merge version-bump PR (respects merge gate from `git-workflow` skill)
3. Pull default branch locally; verify the merged version is present
4. Create **signed** tag: `git tag -s vX.Y.Z -m "vX.Y.Z"`
5. Push tag: `git push origin vX.Y.Z`
6. Monitor the Release workflow to green
7. **Only after green** declare the repo released

### Supervisor halts on first failure

If any repo's Release workflow fails, **halt further releases**. Do not continue to the next repo. Produce a rollback plan (`gh release delete`, or version-bump-back PR) before the user asks. This prevents the 30-failed-plugin-releases pattern.

### Final report

After all releases complete, output a table:

| Repo | Old | New | Tag URL | Release Workflow |
|------|-----|-----|---------|------------------|
| owner/a | 1.2.3 | 1.2.4 | link | ✅ green |
| owner/b | 1.2.3 | 1.2.4 | link | ❌ failed — see link |

## Enumerating Target Repos

```bash
# All repos in an org with a given topic
gh repo list OWNER --topic claude-skill --limit 100 --json name,url,defaultBranchRef

# All repos matching a name pattern
gh repo list OWNER --limit 100 --json name,url | jq '.[] | select(.name | endswith("-skill"))'

# Local worktree discovery
find ~/projects -maxdepth 3 -name ".bare" -type d | sed 's|/.bare||'
```

## Cache-Safety for Batch Operations

When iterating across many local worktrees, it's easy to edit an installed skill/plugin cache by mistake. Before any write in a multi-repo loop:

```bash
for repo in "${REPOS[@]}"; do
  cd "$repo"
  pwd_real=$(realpath .)
  case "$pwd_real" in
    */.claude/skills/*|*/.claude/plugins/cache/*|*/.bare/*)
      echo "REFUSING to edit cache path: $pwd_real"; exit 1 ;;
  esac
  # ... actual work ...
done
```

This is the same worktree-authority rule as `git-workflow`, enforced inside the batch loop.

## Common Anti-Patterns

| Anti-pattern | Consequence | Fix |
|--------------|-------------|-----|
| Tag pushed before version-bump PR merged | Release workflow runs on old version | Enforce order in supervisor prompt |
| Sequential (not parallel) processing of independent repos | Hours wasted; user interrupts | Dispatch as parallel subagents |
| "Should work now, try it" without per-repo verification | One failure poisons the batch | Collect results in a table, verify each |
| Shared branch name across repos (e.g. `bump-version`) | PR searches return wrong repo | Include repo name in branch: `bump-<repo>-v1.2.4` |
| Squash-merging version-bump PRs when repo uses atomic commits | Lost signatures, CI confusion | Respect repo merge policy per `git-workflow` |
