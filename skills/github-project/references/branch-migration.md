# Branch Migration Reference

Guide for migrating from `master` to `main` as default branch.

## Migration Steps

### Step 1: Rename the branch on GitHub

GitHub renames a branch in one call. The rename moves the branch
protection, retargets open pull requests, redirects old URLs, and — for
the default branch — changes `default_branch` too:

```bash
# Back up the current protection first (admin-only endpoint)
gh api repos/{owner}/{repo}/branches/master/protection > master-protection.backup.json

gh api -X POST repos/{owner}/{repo}/branches/master/rename -f new_name=main \
  --jq '{name, protected}'

# Read back — a 2xx is not proof
gh api repos/{owner}/{repo} --jq .default_branch            # main
gh api repos/{owner}/{repo}/branches --jq '.[].name'         # no master
gh api repos/{owner}/{repo}/branches/main/protection \
  --jq '{rcr: .required_conversation_resolution.enabled, fp: .allow_force_pushes.enabled}'
```

Do not push `main` and delete `master` by hand instead. GitHub refuses to
delete the default branch, and the manual path leaves open pull requests on
a base that no longer exists.

### Step 2: Prevent master from being re-created

Block the name with a **ruleset**, the same shape the Netresearch fleet uses
(e.g. `netresearch/go-cron`, ruleset "Block master branch recreation"):

```bash
gh api -X POST repos/{owner}/{repo}/rulesets --input - <<'EOF'
{"name": "Block master branch recreation", "target": "branch",
 "enforcement": "active", "bypass_actors": [],
 "conditions": {"ref_name": {"include": ["refs/heads/master"], "exclude": []}},
 "rules": [{"type": "creation"}]}
EOF

gh api repos/{owner}/{repo}/rules/branches/master --jq '[.[].type]'   # ["creation"]
```

Prove the guard fails before relying on it — a push of `master` must be
refused, admins included:

```bash
git push origin refs/remotes/origin/main:refs/heads/master
# remote: - Cannot create ref due to creations being restricted.
# ! [remote rejected] ... (push declined due to repository rule violations)
```

Classic branch protection cannot do this: `PUT .../branches/master/protection`
answers `404 Branch not found` once the branch is gone. Rulesets are available
on public repositories and on paid plans; a free-plan private repository
answers 403.

### Step 3: Update the local clone

```bash
git branch -m master main
git fetch origin --prune
git branch -u origin/main main
git remote set-head origin -a
```

In a bare-repo worktree layout (`.bare/` + one folder per branch) the bare
repository's `HEAD` points at `master` too:

```bash
git -C .bare worktree remove ../master
git -C .bare branch -m master main
git -C .bare symbolic-ref HEAD refs/heads/main
git -C .bare fetch --prune origin
git -C .bare branch -u origin/main main
git -C .bare worktree add ../main main
git -C .bare remote set-head origin -a
```

### Step 4: Update CI/CD workflows

```bash
grep -rn "master" .github/workflows/
# Common patterns to update:
# - branches: [master] → branches: [main]
# - refs/heads/master → refs/heads/main
```

**Check `.github/template.yaml` first.** In a repository managed by a
`netresearch/.github` template, the workflow files are copies of the
template, and the `Template Drift` check fails on any local edit. The
templates keep `branches: [main, master]` on purpose, so leave those lines
alone; a blanket `sed s/master/main/g` breaks the drift check. Do not touch
`dev-master` constraints on *dependencies* in `composer.json` either — they
name the dependency's branch, not this repository's.

### Step 5: Update documentation

Search and replace branch references:
```bash
# Find all references to master branch in docs
grep -rn "master" --include="*.md" --include="*.rst" --include="*.txt"
```

| File | Pattern | Update to |
|------|---------|-----------|
| README.md | `badge/branch-master` | `badge/branch-main` |
| README.md | `github.com/org/repo/tree/master` | `tree/main` |
| README.md | `github.com/org/repo/blob/master` | `blob/main` |
| README.md | `?branch=master` | `?branch=main` |
| CONTRIBUTING.md | "merge into master" | "merge into main" |
| docs/*.md | `/master/` links | `/main/` |
| package.json | `"repository": "...#master"` | `#main` |
| composer.json | `"dev-master"` or `#master` | `"dev-main"` or `#main` |

```bash
# Bulk update in markdown files
find . -name "*.md" -exec sed -i 's|/master/|/main/|g; s|/master"|/main"|g; s|branch-master|branch-main|g' {} \;
```

### Step 6: Notify team

Team members must update local repos:
```bash
git checkout master
git branch -m master main
git fetch origin
git branch -u origin/main main
git remote set-head origin -a
```
