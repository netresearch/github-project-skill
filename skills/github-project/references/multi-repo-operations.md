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

## Pre-Flight Per-Repo Checks

Before touching each repo in the batch, check three things the dry-run manifest won't catch — they tend to surface as 30 silent failures across a fleet loop:

### 1. Default branch name

Not every repo uses `main`. Some legacy repos are on `master`; forks can be on anything.

```bash
DEFAULT_BRANCH=$(gh api "repos/$REPO" --jq '.default_branch')
```

Use `$DEFAULT_BRANCH` everywhere a script would otherwise hard-code `main`. Pushing to the wrong branch either silently creates a new branch or fails with a confusing rejection.

### 2. Archived repos

Archived repos reject most writes with a generic permission error. Dependabot/Renovate sometimes still open PRs on them (via the pre-archive config), and a batch loop that tries to merge them fails cryptically.

```bash
ARCHIVED=$(gh api "repos/$REPO" --jq '.archived')
if [[ "$ARCHIVED" == "true" ]]; then
  # Skip, or handle specially: unarchive → close PR → re-archive.
  continue
fi
```

Never enable auto-merge on archived repos — the auto-merge plumbing fails at set-up time with "archived" errors.

### 3. Contents API vs branch protection

`gh api -X PUT repos/.../contents/...` is the fastest path for tiny single-file edits across a fleet — but it returns HTTP 409 on any repo that requires PRs, a merge queue, or signed commits. If your batch mixes repos with and without branch protection, this path breaks mid-loop and leaves half the fleet updated.

**Safer default for batch file edits**: open a one-commit PR per repo even when the Contents API would work. Gives you a reviewable diff, matches any future signing/protection rule tightening, and keeps behavior consistent across the fleet.

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

- `plugin.json.version` is present (authoritative) and `composer.json` has **no** `version` field (Packagist derives the version from git tags); if `SKILL.md` frontmatter carries a `metadata.version`, it must match `plugin.json.version`
- For repos that also ship via npm: `package.json.version` is either the placeholder `0.0.0-source` (publish-time-rewritten by the Release workflow) **or** matches `plugin.json` (for coordinator-style packages, e.g. `@netresearch/agent-skill-coordinator`). Mixing the two within one repo is the bug pattern to look for.
- Current git tag on default branch is not already the target version
- CI on default branch is green
- No pending version-bump PR already open

For Netresearch skill repos, use the shipped `scripts/check-version-parity.sh` from `skill-repo-skill`:

```bash
# From the target repo root
skills/skill-repo/scripts/check-version-parity.sh            # parity only
skills/skill-repo/scripts/check-version-parity.sh v1.2.4     # also require tag parity
```

That script handles the Netresearch conventions (`plugin.json` has the authoritative version, `composer.json` must not have one, `SKILL.md` `metadata.version` in frontmatter matches `plugin.json`, and `package.json.version` is either `0.0.0-source` for git-installed skill packages or matches `plugin.json` for npm-published coordinator-style packages). Don't copy the snippet below inline — it was a sketch for illustration; the real script handles empty-arg mode, missing files, glob-empty iteration, and the quoted-or-unquoted frontmatter form. Call the shipped script.

```bash
# Illustrative only — for non-skill repos, adapt the shape but handle empties
PLUGIN_VERSION=$(jq -r '.version // empty' .claude-plugin/plugin.json 2>/dev/null)
[[ -z "$PLUGIN_VERSION" ]] && { echo "no plugin.json.version"; exit 1; }
# ...same shape, using jq // empty to avoid "null" strings, and quoting frontmatter regex
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
# All repos in an org with a given topic. --limit 100 caps the page;
# for larger orgs, raise or iterate with pagination.
gh repo list OWNER --topic claude-skill --limit 500 --json name,url,defaultBranchRef

# All repos matching a name pattern
gh repo list OWNER --limit 500 --json name,url | jq '.[] | select(.name | endswith("-skill"))'

# Local worktree discovery
find ~/projects -maxdepth 3 -name ".bare" -type d | sed 's|/.bare||'
```

## Cache-Safety for Batch Operations

When iterating across many local worktrees, it's easy to edit an installed skill/plugin cache by mistake. Before any write in a multi-repo loop:

```bash
for repo in "${REPOS[@]}"; do
  # `cd` can fail (missing dir, permissions) — bail the iteration so the
  # work below doesn't run in the previous repo's cwd, which would silently
  # corrupt that repo.
  if ! cd "$repo"; then
    echo "SKIP: cannot cd to $repo" >&2
    continue
  fi

  pwd_real=$(realpath .)
  case "$pwd_real" in
    */.claude/skills/*|*/.claude/skills|*/.claude/plugins/cache/*|*/.claude/plugins/cache|*/.bare/*|*/.bare)
      echo "REFUSING to edit cache path: $pwd_real" >&2
      cd - >/dev/null || exit 1
      continue
      ;;
  esac

  # ... actual work ...

  cd - >/dev/null || exit 1   # pop back before the next iteration
done
```

`cd -` restores the original working directory between iterations so a failure partway through doesn't leave the shell in the wrong repo. `continue` (not `exit`) on a single-repo failure keeps the rest of the batch moving — a single bad repo should not abort the run; the summary table at the end reports it.

This is the same worktree-authority rule as `git-workflow`, enforced inside the batch loop.

## Template-Drift Resolution Pattern

When a consumer repo's template-drift check fails and the fix is "remove a thing that doesn't apply here" (ecosystem, workflow, config entry), the drift is usually a **template bug**, not a consumer bug — the template was written too broad for the class of repo it's applied to.

**Naive fix:** patch only the consumer. The drift check stays red forever because the template still declares the thing the consumer is missing. Adding an `intentional-drift:` exception works but accumulates per-repo carve-outs that future template authors don't see.

**Correct fix:** patch the template AND the consumer in the same sweep. The template PR is the forward fix (next consumer inherits the correction); the consumer PR clears the current red.

```
1. Identify all consumers of the affected template path
   gh search code --owner netresearch "templates/<template-name>" --limit 20

2. Open the template-side PR first
   - Remove the bad entry / tighten the template
   - Reference the first observed consumer failure (URL of the red run)
   - Flag that consumers will drift until synced; list them in the PR body

3. Open the consumer-side PR(s) matching the template change
   - Cross-reference: "Matches netresearch/.github#NN"
   - Merge both in the same session so the drift window closes quickly

4. Enable auto-merge on both. The consumer waits on its drift check,
   which starts passing the moment the template PR lands.
```

**Rule of thumb for template scope:** the template should carry only what EVERY consumer of that class actually needs. A `go-lib` template with an `npm` dependabot entry is wrong because most Go libraries don't ship `package.json`. A `go-app` template with an `npm` entry is defensible — some go-apps DO ship frontend assets — but the class is loose enough that per-consumer overrides become common. When you see carve-outs accumulating in `intentional-drift:` lists, that's a signal the template is too broad for its consumer base and the classes should be split (e.g. `go-app` vs `go-app-headless`).

See [dependency-management.md](./dependency-management.md) for which Dependabot ecosystems hard-fail when their manifest is missing (the common source of template drift on Go repos).

## Common Anti-Patterns

| Anti-pattern | Consequence | Fix |
|--------------|-------------|-----|
| Tag pushed before version-bump PR merged | Release workflow runs on old version | Enforce order in supervisor prompt |
| Sequential (not parallel) processing of independent repos | Hours wasted; user interrupts | Dispatch as parallel subagents |
| "Should work now, try it" without per-repo verification | One failure poisons the batch | Collect results in a table, verify each |
| Shared branch name across repos (e.g. `bump-version`) | PR searches return wrong repo | Include repo name in branch: `bump-<repo>-v1.2.4` |
| Squash-merging version-bump PRs when repo uses atomic commits | Lost signatures, CI confusion | Respect repo merge policy per `git-workflow` |
