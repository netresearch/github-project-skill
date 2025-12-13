---
name: github-project
description: "GitHub repository setup and platform-specific features. This skill should be used when creating new GitHub repositories, configuring branch protection rules, setting up GitHub Issues/Discussions/Projects, managing PR review workflows, configuring Dependabot/Renovate auto-merge, or checking GitHub project configuration. Focuses on GitHub platform features, not CI/CD pipelines or language-specific tooling. By Netresearch."
---

# GitHub Project Skill

GitHub platform configuration and repository management patterns. This skill focuses exclusively on **GitHub-specific features**.

## Scope Boundaries

**This Skill Covers:**
- Branch protection rules and PR workflows
- CODEOWNERS configuration
- GitHub Issues, Discussions, Projects
- Dependabot/Renovate auto-merge
- GitHub Releases configuration
- Repository collaboration features

**Delegate to Other Skills:**
- CI/CD pipelines → `go-development`, `php-modernization`, `typo3-testing`
- Security scanning (CodeQL, gosec) → `security-audit`
- SLSA, SBOMs, supply chain → `enterprise-readiness`
- Git branching strategies, conventional commits → `git-workflow`

## Triggers

**Setup & Configuration:**
- Creating a new GitHub repository
- "Check my GitHub project setup"
- "Configure branch protection"
- "Set up GitHub Issues/Discussions"
- "How do I require PR reviews?"
- "Auto-merge Dependabot PRs"
- "Configure CODEOWNERS"

**Troubleshooting (PR Merge Blocked):**
- "PR can't be merged" / "merge is blocked"
- "unresolved conversations" / "unresolved comments"
- "required reviews not met"
- "CODEOWNERS review required"
- "status checks failed" (for branch protection context)
- `gh pr merge` returns error

**Branch Migration:**
- "rename master to main"
- "change default branch"
- "migrate from master"
- "prevent master branch"
- "block master from being created"

## Workflows

### New Repository Setup

To set up a new GitHub repository:

1. Create essential files: README.md, LICENSE, SECURITY.md
2. Configure `.github/` directory structure (see `references/repository-structure.md`)
3. Set up branch protection on `main` branch
4. Configure CODEOWNERS for automatic reviewer assignment
5. Create issue and PR templates
6. Enable Dependabot or Renovate for dependency updates
7. Configure auto-merge workflow for dependency PRs
8. Set up release notes configuration

Run verification: `./scripts/verify-github-project.sh /path/to/repo`

### Branch Configuration

**Required branch settings:**

| Setting | Value | Rationale |
|---------|-------|-----------|
| Default branch name | `main` | Industry standard |
| Default branch protected | ✅ | Prevent direct pushes |
| Allowed merge method | **Rebase only** | Clean linear history |
| Delete branch on merge | ✅ | Keep repo clean |

To configure via GitHub CLI:

```bash
# Ensure default branch is named "main"
gh api repos/{owner}/{repo} --jq '.default_branch'

# Configure merge settings (rebase only, delete on merge)
gh repo edit --enable-rebase-merge --disable-merge-commit --disable-squash-merge --delete-branch-on-merge
```

### Renaming "master" to "main"

To migrate from `master` to `main` as default branch:

**Step 1: Rename locally and push**
```bash
# Rename local branch
git branch -m master main

# Push new branch to remote
git push -u origin main
```

**Step 2: Update GitHub default branch**
```bash
# Set main as default (via API)
gh api repos/{owner}/{repo} --method PATCH -f default_branch=main

# Or via gh repo edit
gh repo edit --default-branch main
```

**Step 3: Update branch protection**
```bash
# Copy protection rules from master to main (if any existed)
# Then delete master protection
gh api repos/{owner}/{repo}/branches/master/protection --method DELETE 2>/dev/null || true

# Set up protection on main (see Branch Protection Configuration below)
```

**Step 4: Delete old master branch**
```bash
# Delete remote master
git push origin --delete master
```

**Step 5: Prevent master from being re-created**

Create a branch protection rule for `master` that blocks all pushes:

```bash
# Create restrictive rule for "master" branch name
gh api repos/{owner}/{repo}/branches/master/protection \
  --method PUT \
  -f required_status_checks=null \
  -f enforce_admins=true \
  -f required_pull_request_reviews='{"required_approving_review_count":6,"dismiss_stale_reviews":true}' \
  -f restrictions='{"users":[],"teams":[]}' \
  -f allow_force_pushes=false \
  -f allow_deletions=false
```

This creates a "ghost" protection rule that:
- Requires 6 approvals (effectively blocking all PRs)
- Restricts pushes to nobody
- Prevents the branch from being created

**Step 6: Update CI/CD workflows**
```bash
# Find and update workflow files
grep -rl "master" .github/workflows/ | xargs sed -i 's/master/main/g'

# Common patterns to update:
# - branches: [master] → branches: [main]
# - on: push: branches: master → main
# - refs/heads/master → refs/heads/main
```

**Step 7: Update documentation**

Search and replace branch references:
```bash
# Find all references to master branch in docs
grep -rn "master" --include="*.md" --include="*.rst" --include="*.txt"

# Common updates needed:
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

```bash
# Bulk update in markdown files
find . -name "*.md" -exec sed -i 's|/master/|/main/|g; s|/master"|/main"|g; s|branch-master|branch-main|g' {} \;
```

**Step 8: Notify team**

Team members must update local repos:
```bash
git checkout master
git branch -m master main
git fetch origin
git branch -u origin/main main
git remote set-head origin -a
```

### Branch Protection Configuration

To configure branch protection via GitHub CLI:

```bash
# View current protection
gh api repos/{owner}/{repo}/branches/main/protection

# Set branch protection
gh api repos/{owner}/{repo}/branches/main/protection \
  --method PUT \
  -f required_status_checks='{"strict":true,"contexts":["test","lint"]}' \
  -f enforce_admins=true \
  -f required_pull_request_reviews='{"required_approving_review_count":1,"dismiss_stale_reviews":true,"require_code_owner_reviews":true}' \
  -f restrictions=null \
  -f required_conversation_resolution=true
```

**Recommended Settings:**
| Setting | Value | Purpose |
|---------|-------|---------|
| Require pull request | ✅ | Enforce code review |
| Required approvals | 1+ | Based on team size |
| Dismiss stale reviews | ✅ | Re-review after changes |
| Require CODEOWNERS review | ✅ | Domain expert review |
| Require conversation resolution | ✅ | All comments addressed |
| Do not allow force pushes | ✅ | Protect history |
| Allow rebase merge | ✅ | Clean linear history |
| Disable merge commits | ✅ | No merge bubbles |
| Disable squash merge | ✅ | Preserve commit granularity |
| Delete branch on merge | ✅ | Auto-cleanup merged branches |

### PR Comment Resolution Workflow

To enforce PR comment resolution:

1. Enable "Require conversation resolution" in branch protection
2. During review:
   - Reviewers leave line-specific comments
   - Author responds to each comment
   - Author clicks "Resolve conversation" after addressing
3. PR cannot merge until all conversations are resolved
4. Options for each thread:
   - "Resolve conversation" → Mark as addressed
   - Reply with explanation → Then resolve
   - "Won't fix" with reason → Then resolve

### CODEOWNERS Setup

To configure automatic reviewer assignment:

1. Create `.github/CODEOWNERS`
2. Define ownership patterns (last matching pattern wins):

```
# Default owners for everything
* @org/maintainers

# Directory ownership
/src/auth/ @org/security-team
/docs/ @org/docs-team

# File pattern ownership
*.sql @org/dba-team
/.github/ @org/maintainers
```

3. Enable "Require review from CODEOWNERS" in branch protection

### Dependency Auto-Merge Setup

To configure automatic merging of dependency updates:

1. Configure Dependabot or Renovate (see `references/dependency-management.md`)
2. Create auto-merge workflow using template: `templates/auto-merge.yml.template`
3. Workflow auto-approves and merges minor/patch updates
4. Major updates require manual review

### GitHub Discussions Setup

To enable Discussions:

1. Go to **Settings → Features → Discussions**
2. Create categories:
   - 📣 Announcements (maintainers only)
   - 💬 General
   - 💡 Ideas
   - 🙏 Q&A (Question/Answer format)
3. Add Discussions link to issue template chooser

**Use Discussions for:** Questions, ideas, announcements
**Use Issues for:** Bug reports, confirmed features, actionable tasks

### GitHub Releases Configuration

To configure automatic release notes:

1. Create `.github/release.yml`:

```yaml
changelog:
  exclude:
    authors: [dependabot, renovate]
  categories:
    - title: 🚀 Features
      labels: [enhancement]
    - title: 🐛 Bug Fixes
      labels: [bug]
    - title: 📚 Documentation
      labels: [documentation]
```

2. Create releases via CLI:

```bash
gh release create v1.0.0 --generate-notes
```

### Troubleshooting: PR Merge Blocked

When a PR cannot be merged, diagnose the cause:

**Step 1: Check PR status**
```bash
# View PR details including merge state
gh pr view <number> --json mergeable,mergeStateStatus,reviewDecision,statusCheckRollup

# Check for blocking issues
gh pr checks <number>
```

**Step 2: Identify the blocker**

| Symptom | Cause | Resolution |
|---------|-------|------------|
| `BLOCKED` mergeStateStatus | Unresolved conversations | Resolve all review threads |
| `REVIEW_REQUIRED` reviewDecision | Missing approvals | Request reviews from required reviewers |
| `CHANGES_REQUESTED` reviewDecision | Changes requested | Address feedback, request re-review |
| Failed checks in `statusCheckRollup` | CI/CD failures | Fix failing tests/lints |
| `CODEOWNERS review required` | Missing code owner approval | Get approval from designated owners |

**Step 3: Check unresolved conversations**
```bash
# View all PR comments (look for unresolved threads)
gh pr view <number> --comments

# Via API for detailed thread status
gh api repos/{owner}/{repo}/pulls/<number>/comments
```

**Step 4: Resolution actions**

For **unresolved conversations**:
1. Review each comment thread in the PR
2. Address the feedback or reply with explanation
3. Click "Resolve conversation" on each thread
4. All threads must show as resolved before merge

For **missing reviews**:
```bash
# Request review from specific users
gh pr edit <number> --add-reviewer username

# Check who needs to review
gh pr view <number> --json reviewRequests
```

For **CODEOWNERS blocking**:
```bash
# Check which files triggered CODEOWNERS
gh pr view <number> --json files

# Cross-reference with .github/CODEOWNERS to identify required reviewers
```

**Common `gh pr merge` errors:**

| Error Message | Meaning | Fix |
|---------------|---------|-----|
| `Pull request is not mergeable` | Branch protection blocking | Run diagnosis steps above |
| `Required status check "X" is expected` | CI not run or pending | Wait for CI or trigger manually |
| `At least 1 approving review is required` | No approvals yet | Request and obtain review |
| `Changes were made after the most recent approval` | Stale approval | Request re-review |

## Quick CLI Reference

```bash
# Repository
gh repo view
gh repo edit --enable-discussions

# Issues
gh issue list
gh issue create
gh issue edit 123 --add-label "priority: high"

# Pull requests
gh pr list
gh pr create
gh pr review --approve
gh pr merge --squash

# Releases
gh release create v1.0.0 --generate-notes

# Labels
gh label create "name" --color "hex" --description "desc"

# Projects
gh project create --title "Project Name"
```

## Resources

| Resource | Purpose |
|----------|---------|
| `references/repository-structure.md` | Standard files and directory layout |
| `references/dependency-management.md` | Dependabot/Renovate configuration patterns |
| `templates/` | Ready-to-use GitHub configuration templates |
| `scripts/verify-github-project.sh` | Verification script for project setup |

## Verification

To check GitHub project configuration:

```bash
./scripts/verify-github-project.sh /path/to/repository
```

Checks: documentation files, CODEOWNERS, dependency management, issue/PR templates, auto-merge workflow, release configuration.
