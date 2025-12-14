---
name: github-project
description: "GitHub repository setup and platform-specific features. This skill should be used when creating new GitHub repositories, configuring branch protection rules, setting up GitHub Issues/Discussions/Projects, creating sub-issues and issue hierarchies, managing PR review workflows, configuring Dependabot/Renovate auto-merge, or checking GitHub project configuration. Focuses on GitHub platform features, not CI/CD pipelines or language-specific tooling. By Netresearch."
---

# GitHub Project Skill

GitHub platform configuration and repository management patterns. This skill focuses exclusively on **GitHub-specific features**.

## Scope Boundaries

**This Skill Covers:**
- Branch protection rules and PR workflows
- CODEOWNERS configuration
- GitHub Issues, Discussions, Projects
- Sub-issues and issue hierarchies (parent/child relationships)
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

**Sub-Issues & Issue Hierarchies:**
- "Create sub-issues"
- "Add child issues to parent"
- "Link issues as parent/child"
- "Break down issue into sub-tasks"
- "Set up issue hierarchy"
- "Convert checklist to sub-issues"

**Troubleshooting (PR Merge Blocked):**
- "PR can't be merged" / "merge is blocked"
- "unresolved conversations" / "unresolved comments"
- "required reviews not met"
- "CODEOWNERS review required"
- "status checks failed" (for branch protection context)
- `gh pr merge` returns error

**Troubleshooting (Auto-Merge Failures):**
- "auto-merge not working" / "Dependabot PR not merging"
- "Merge method squash merging is not allowed"
- "Merge method merge commit is not allowed"
- "required status check not found"
- "status check name mismatch"
- PRs stuck with auto-merge enabled

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
| composer.json | `"dev-master"` or `#master` | `"dev-main"` or `#main` |

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

### Troubleshooting: Auto-Merge Failures

When auto-merge is enabled but PRs aren't merging automatically:

**Step 1: Check repo merge settings vs workflow merge method**
```bash
# View current merge method settings
gh api repos/{owner}/{repo} --jq '{
  allow_squash_merge,
  allow_merge_commit,
  allow_rebase_merge,
  delete_branch_on_merge
}'
```

**Step 2: Identify merge method mismatch**

| Workflow Uses | Repo Setting Required | Error Message |
|---------------|----------------------|---------------|
| `gh pr merge --squash` | `allow_squash_merge: true` | "Merge method squash merging is not allowed" |
| `gh pr merge --merge` | `allow_merge_commit: true` | "Merge method merge commit is not allowed" |
| `gh pr merge --rebase` | `allow_rebase_merge: true` | "Merge method rebase is not allowed" |

**Step 3: Fix merge method alignment**

Option A - Update workflow to match repo settings (recommended for rebase-only repos):
```yaml
# In .github/workflows/auto-merge-deps.yml
- run: gh pr merge --auto --rebase "$PR_URL"  # Match repo's allowed method
```

Option B - Update repo settings to allow workflow's merge method:
```bash
# Enable squash merge (if workflow uses --squash)
gh api repos/{owner}/{repo} --method PATCH -f allow_squash_merge=true

# Or configure for rebase-only (recommended)
gh api repos/{owner}/{repo} --method PATCH \
  -f allow_rebase_merge=true \
  -f allow_merge_commit=false \
  -f allow_squash_merge=false
```

**Step 4: Validate required status checks**

Status check names must **exactly match** what workflows produce:

```bash
# View required status checks on branch protection
gh api repos/{owner}/{repo}/branches/main/protection/required_status_checks \
  --jq '.contexts[]'

# View actual check names from a recent PR
gh pr checks <number> --json name --jq '.[].name'
```

**Common status check name mismatches:**

| Expected (Branch Protection) | Actual (Workflow Output) | Issue |
|------------------------------|--------------------------|-------|
| `Analyze (javascript-typescript)` | `Analyze (javascript)` | Language detection differs |
| `build` | `Build / build` | Job name includes workflow name |
| `test` | `test (ubuntu-latest, 18)` | Matrix parameters appended |

**Step 5: Fix status check names**
```bash
# Update branch protection to match actual check names
gh api repos/{owner}/{repo}/branches/main/protection/required_status_checks \
  --method PATCH \
  -f strict=true \
  --input - <<EOF
{
  "contexts": ["Analyze (javascript)", "build", "test"]
}
EOF
```

**Step 6: Re-trigger stuck PRs**

After fixing settings, re-trigger auto-merge on existing PRs:
```bash
# Update PR branch to trigger checks
gh pr update-branch <number> --rebase

# Or close and reopen to re-evaluate
gh pr close <number> && gh pr reopen <number>
```

**Auto-merge compatibility checklist:**

| Check | Command | Expected |
|-------|---------|----------|
| Merge method alignment | `gh api repos/{owner}/{repo} --jq '.allow_rebase_merge'` | Matches workflow flag |
| Status checks pass | `gh pr checks <number>` | All green |
| Status check names match | Compare `gh pr checks` vs branch protection | Exact match |
| Reviews complete | `gh pr view <number> --json reviewDecision` | `APPROVED` |
| No merge conflicts | `gh pr view <number> --json mergeable` | `MERGEABLE` |
| Auto-merge enabled | `gh pr view <number> --json autoMergeRequest` | Not null |

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

### Sub-Issues Configuration

GitHub's sub-issues feature enables parent-child relationships between issues, supporting up to 8 levels of hierarchy and 100 sub-issues per parent. This replaced the deprecated tasklists feature (sunset April 2025).

**Important:** The `gh` CLI does not support sub-issues directly. You must use the GraphQL API.

#### Creating Sub-Issues

**Step 1: Create the issues normally**
```bash
# Create parent issue
gh issue create --title "Parent feature request" --body "Main tracking issue"
# Returns: https://github.com/owner/repo/issues/100

# Create child issues
gh issue create --title "Sub-task 1" --body "First sub-task"
# Returns: https://github.com/owner/repo/issues/101

gh issue create --title "Sub-task 2" --body "Second sub-task"
# Returns: https://github.com/owner/repo/issues/102
```

**Step 2: Get issue node IDs (required for GraphQL)**
```bash
gh api graphql -f query='
{
  repository(owner: "OWNER", name: "REPO") {
    parent: issue(number: 100) { id }
    child1: issue(number: 101) { id }
    child2: issue(number: 102) { id }
  }
}'
```

Output:
```json
{
  "data": {
    "repository": {
      "parent": { "id": "I_kwDOXXXXXX" },
      "child1": { "id": "I_kwDOYYYYYY" },
      "child2": { "id": "I_kwDOZZZZZZ" }
    }
  }
}
```

**Step 3: Link sub-issues to parent**
```bash
# Add first sub-issue
gh api graphql -f query='
mutation {
  addSubIssue(input: {
    issueId: "I_kwDOXXXXXX",
    subIssueId: "I_kwDOYYYYYY"
  }) {
    issue { number title }
    subIssue { number title }
  }
}'

# Add second sub-issue
gh api graphql -f query='
mutation {
  addSubIssue(input: {
    issueId: "I_kwDOXXXXXX",
    subIssueId: "I_kwDOZZZZZZ"
  }) {
    issue { number title }
    subIssue { number title }
  }
}'
```

#### Querying Sub-Issues

**List all sub-issues of a parent:**
```bash
gh api graphql -f query='
{
  repository(owner: "OWNER", name: "REPO") {
    issue(number: 100) {
      number
      title
      subIssues(first: 50) {
        nodes {
          number
          title
          state
        }
        totalCount
      }
    }
  }
}'
```

**Get parent of a sub-issue:**
```bash
gh api graphql -f query='
{
  repository(owner: "OWNER", name: "REPO") {
    issue(number: 101) {
      number
      title
      parent {
        number
        title
      }
    }
  }
}'
```

#### Removing Sub-Issues

```bash
gh api graphql -f query='
mutation {
  removeSubIssue(input: {
    issueId: "I_kwDOXXXXXX",
    subIssueId: "I_kwDOYYYYYY"
  }) {
    issue { number }
    subIssue { number }
  }
}'
```

#### Sub-Issues Best Practices

| Practice | Rationale |
|----------|-----------|
| Use parent as tracking/meta issue | Provides overview and progress tracking |
| Add "tracking" label to parent | Identifies meta-issues in issue lists |
| Keep hierarchy ≤3 levels | Deeper hierarchies become hard to manage |
| Reference upstream PRs in body | Link to external sources for context |
| One sub-issue per distinct feature | Enables independent progress and assignment |

#### Sub-Issues Behavior

- **Inheritance**: Sub-issues inherit Project and Milestone from parent by default
- **Cross-org support**: Sub-issues can belong to different organizations than parent
- **Progress tracking**: Parent issue shows completion percentage in GitHub UI
- **Limits**: Maximum 100 sub-issues per parent, 8 levels of nesting

#### Migration from Tasklists

Tasklists were sunset April 30, 2025. To convert old tasklist items:

1. Identify issues with tasklist markdown (`- [ ] #123`)
2. Create sub-issue relationships using GraphQL API above
3. Remove tasklist markdown from issue body (or leave as reference)

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

# Sub-Issues (GraphQL only - gh CLI doesn't support directly)
# Get issue node ID
gh api graphql -f query='{repository(owner:"OWNER",name:"REPO"){issue(number:123){id}}}'
# Add sub-issue (requires node IDs)
gh api graphql -f query='mutation{addSubIssue(input:{issueId:"PARENT_ID",subIssueId:"CHILD_ID"}){issue{number}subIssue{number}}}'
# List sub-issues
gh api graphql -f query='{repository(owner:"OWNER",name:"REPO"){issue(number:123){subIssues(first:50){nodes{number title state}}}}}'
# Remove sub-issue
gh api graphql -f query='mutation{removeSubIssue(input:{issueId:"PARENT_ID",subIssueId:"CHILD_ID"}){issue{number}}}'
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
