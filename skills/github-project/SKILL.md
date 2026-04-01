---
name: github-project
description: "Use when PRs won't merge or show BLOCKED status, auto-merge fails for Dependabot/Renovate, branch protection or rulesets need configuring, GitHub Actions workflows have issues or CI is failing, setting up CODEOWNERS or PR templates, or diagnosing any GitHub repository configuration problem."
license: "(MIT AND CC-BY-SA-4.0). See LICENSE-MIT and LICENSE-CC-BY-SA-4.0"
compatibility: "Requires gh CLI, git."
metadata:
  author: Netresearch DTT GmbH
  version: "2.12.0"
  repository: https://github.com/netresearch/github-project-skill
allowed-tools: Bash(gh:*) Bash(git:*) Bash(grep:*) Read Write
---

# GitHub Project Skill

GitHub repository configuration, troubleshooting, and collaboration workflow best practices.

## When to Use

- PR won't merge, shows BLOCKED, or has unresolved review threads
- Auto-merge not working for Dependabot/Renovate PRs
- Solo maintainer needs auto-approve for their own PRs
- Branch protection, rulesets, or `enforce_admins` audit
- GitHub Actions workflow problems, CI failures, or permission issues
- Signed commit merge failures (rebase cannot be auto-signed)
- CodeQL default setup conflicts with custom workflows
- OpenSSF Scorecard improvements (token permissions, pinned deps)
- Setting up CODEOWNERS, issue templates, PR templates, or release labeling
- Fork PR merge base issues (too many commits shown)

## Quick Diagnostics

### PR Won't Merge

```bash
gh api graphql -f query='query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){pullRequest(number:$pr){
    mergeStateStatus reviewDecision mergeable
    reviewThreads(first:50){nodes{isResolved comments(first:1){nodes{body}}}}
  }}
}' -f owner=OWNER -f repo=REPO -F pr=NUMBER --jq '.data.repository.pullRequest'
```

### Solo Maintainer: PRs Stuck on REVIEW_REQUIRED

Use `assets/pr-quality.yml.template` for auto-approve with `required_approving_review_count >= 1`. See `references/auto-merge-guide.md`.

### Auto-merge Setup

Requirements: `allow_auto_merge` on repo, `pull_request_target` trigger (not `pull_request`), check `user.login` (not `github.actor`), `gh pr merge --auto` with dynamic strategy. See `references/auto-merge-guide.md`.

### Auto-merge Not Working

```bash
gh api graphql -f query='query{repository(owner:"OWNER",name:"REPO"){
  pullRequest(number:PR){autoMergeRequest{enabledBy{login}}}
}}' --jq '.data.repository.pullRequest.autoMergeRequest'

gh api repos/OWNER/REPO/branches/main/protection/required_pull_request_reviews \
  --jq '.bypass_pull_request_allowances.apps[].slug'
```

### GitHub Actions Failing

```bash
gh run list --repo OWNER/REPO --limit 5
gh run view RUN_ID --repo OWNER/REPO --log-failed
gh run rerun RUN_ID --repo OWNER/REPO
```

### Security & Compliance Quick Checks

```bash
gh api repos/OWNER/REPO/branches/main/protection --jq '.enforce_admins.enabled'
gh api repos/OWNER/REPO/code-scanning/default-setup --jq '.state'
gh api graphql -f query='query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){pullRequest(number:$pr){
    reviewThreads(first:50){nodes{id isResolved}}
  }}
}' -f owner=OWNER -f repo=REPO -F pr=NUMBER
```

### Merge Strategy Issues

Rebase merge fails with signed commits: enable squash or auto-detect strategy. Workflow file PRs need manual merge (GITHUB_TOKEN lacks `workflows` scope). Copilot reviewer race conditions: re-run auto-approve workflow. See `references/auto-merge-guide.md`.

## Running Scripts

```bash
scripts/verify-github-project.sh /path/to/repository
```

## References

| Topic | Reference |
|-------|-----------|
| Repository file layout and conventions | `references/repository-structure.md` |
| Branch migration (master to main) | `references/branch-migration.md` |
| Dependabot/Renovate configuration | `references/dependency-management.md` |
| Auto-approve + auto-merge (solo maintainer, bots) | `references/auto-merge-guide.md` |
| Merge strategy for signed commits | `references/merge-strategy.md` |
| Sub-issues and issue hierarchy | `references/sub-issues.md` |
| Release labeling automation | `references/release-labeling.md` |
| gh CLI commands | `references/gh-cli-reference.md` |
| Go, TYPO3, polyglot CI checklists | `references/repo-setup-guide.md` |
| OpenSSF Scorecard, CodeQL, security | `references/security-config.md` |
| Workflow linting (actionlint) | `references/actionlint-guide.md` |
| PR shows too many commits (fork merge base) | `references/pr-commit-cleanup.md` |

---

> **Contributing:** https://github.com/netresearch/github-project-skill
