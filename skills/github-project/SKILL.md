---
name: github-project
description: "Use when PRs won't merge or show BLOCKED, auto-merge fails for Dependabot/Renovate, branch protection needs configuring, GitHub Actions have issues, or setting up CODEOWNERS and rulesets."
---

# GitHub Project Skill

## Overview

GitHub repository setup, configuration, troubleshooting, and best practices for collaboration workflows.

## When to Use

- PR won't merge or shows BLOCKED status
- Auto-merge not working for Dependabot/Renovate PRs
- Solo maintainer needs auto-approve for their own PRs
- Branch protection or ruleset configuration needed
- GitHub Actions workflow problems or CI failures
- Setting up CODEOWNERS, issue templates, or PR templates
- Repository standards compliance (TYPO3, Go, polyglot)

## Quick Diagnostics

### PR Won't Merge

```bash
# Check merge state, review decision, and unresolved threads
gh api graphql -f query='query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){pullRequest(number:$pr){
    mergeStateStatus reviewDecision mergeable
    reviewThreads(first:50){nodes{isResolved comments(first:1){nodes{body}}}}
  }}
}' -f owner=OWNER -f repo=REPO -F pr=NUMBER --jq '.data.repository.pullRequest'
```

### Solo Maintainer: PRs Stuck on REVIEW_REQUIRED

Solo maintainer projects MUST have auto-approve. Use `assets/pr-quality.yml.template` and keep `required_approving_review_count >= 1`. See `references/auto-merge-guide.md` for full setup.

### Auto-merge Not Working

```bash
# Check who enabled auto-merge and bypass apps
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

## Quick Reference

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

## Running Scripts

Verify repository configuration against best practices:

```bash
scripts/verify-github-project.sh /path/to/repository
```

## Using Asset Templates

| Template | Target |
|----------|--------|
| `assets/CODEOWNERS.template` | `.github/CODEOWNERS` |
| `assets/CONTRIBUTING.md.template` | `CONTRIBUTING.md` |
| `assets/SECURITY.md.template` | `SECURITY.md` |
| `assets/bug_report.md.template` | `.github/ISSUE_TEMPLATE/bug_report.md` |
| `assets/feature_request.md.template` | `.github/ISSUE_TEMPLATE/feature_request.md` |
| `assets/PULL_REQUEST_TEMPLATE.md.template` | `.github/PULL_REQUEST_TEMPLATE.md` |
| `assets/dependabot.yml.template` | `.github/dependabot.yml` |
| `assets/renovate.json.template` | `renovate.json` |
| `assets/pr-quality.yml.template` | `.github/workflows/pr-quality.yml` |
| `assets/auto-merge.yml.template` | `.github/workflows/auto-merge.yml` |
| `assets/auto-merge-direct.yml.template` | `.github/workflows/auto-merge.yml` |
| `assets/auto-merge-queue.yml.template` | `.github/workflows/auto-merge.yml` |
| `assets/release-labeler.yml.template` | `.github/workflows/release-labeler.yml` |

## Related Skills

- `go-development` -- Go code patterns and CI/CD workflows
- `enterprise-readiness` -- OpenSSF Scorecard, SLSA provenance, signed releases
- `git-workflow` -- Git branching strategies, conventional commits
- `security-audit` -- OWASP, CVE analysis, deep security audits

## External Resources

- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Branch Protection Guide](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches)
- [Dependabot Documentation](https://docs.github.com/en/code-security/dependabot)

---

> **Contributing:** https://github.com/netresearch/github-project-skill
