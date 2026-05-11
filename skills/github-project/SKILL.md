---
name: github-project
description: "Use when PRs won't merge or show BLOCKED (Copilot-review race), AI reviewer pushback, auto-approve/auto-merge fails for Dependabot/Renovate, branch protection/rulesets need configuring, CI fails, authoring reusable workflows or composite actions, harden-runner setup, or CODEOWNERS / PR templates."
license: "(MIT AND CC-BY-SA-4.0). See LICENSE-MIT and LICENSE-CC-BY-SA-4.0"
compatibility: "Requires gh CLI, git."
metadata:
  author: Netresearch DTT GmbH
  version: "2.14.0"
  repository: https://github.com/netresearch/github-project-skill
allowed-tools: Bash(gh:*) Bash(git:*) Bash(grep:*) Read Write
---

# GitHub Project Skill

GitHub repository configuration, troubleshooting, and collaboration workflow best practices.

## When to Use

- PR won't merge, BLOCKED, or unresolved threads
- Auto-merge fails for Dependabot/Renovate
- Solo maintainer needs auto-approve
- Branch protection, rulesets, `enforce_admins`
- GHA failures or permission issues
- Signed commit merge (rebase can't auto-sign)
- CodeQL default vs custom workflows
- OpenSSF Scorecard (token perms, pinned deps)
- CODEOWNERS, issue/PR templates, release labels
- Fork PR merge base (too many commits)

## Quick Diagnostics

### PR Won't Merge

```bash
gh api graphql -f query='query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){pullRequest(number:$pr){
    mergeStateStatus reviewDecision mergeable
    reviewThreads(first:100){nodes{isResolved comments(first:1){nodes{body}}}}
  }}
}' -f owner=OWNER -f repo=REPO -F pr=NUMBER --jq '.data.repository.pullRequest'
```

### Solo Maintainer: PRs Stuck on REVIEW_REQUIRED

Use `assets/pr-quality.yml.template` for auto-approve with `required_approving_review_count >= 1`.

### Auto-merge Setup

Requirements: `allow_auto_merge` on repo, `pull_request_target` trigger (not `pull_request`), check `user.login` (not `github.actor`), `gh pr merge --auto` with dynamic strategy.

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
    reviewThreads(first:100){nodes{id isResolved}}
  }}
}' -f owner=OWNER -f repo=REPO -F pr=NUMBER
```

### Merge Strategy Issues

See `references/auto-merge-guide.md` for: rebase-merge-with-signed-commits fixes, workflow-file PR manual merges, and the Copilot-review auto-approve race.

## Running Scripts

```bash
scripts/verify-github-project.sh /path/to/repository
```

## References

| Topic | Reference |
|-------|-----------|
| Repository file layout | `references/repository-structure.md` |
| Branch migration (master to main) | `references/branch-migration.md` |
| Dependabot/Renovate configuration | `references/dependency-management.md` |
| Auto-approve + auto-merge | `references/auto-merge-guide.md` |
| Merge strategy for signed commits | `references/merge-strategy.md` |
| Sub-issues and issue hierarchy | `references/sub-issues.md` |
| Release labeling automation | `references/release-labeling.md` |
| gh CLI commands | `references/gh-cli-reference.md` |
| Go, TYPO3, polyglot CI checklists | `references/repo-setup-guide.md` |
| OpenSSF Scorecard, CodeQL, security | `references/security-config.md` |
| Workflow linting (actionlint) | `references/actionlint-guide.md` |
| Bash pitfalls in workflow `run:` steps | `references/workflow-bash-patterns.md` |
| PR shows too many commits (fork merge base) | `references/pr-commit-cleanup.md` |
| Multi-repo batch ops | `references/multi-repo-operations.md` |
| Reusable workflow supply-chain trust + SHA pinning | `references/reusable-workflow-security.md` |
| Reusable workflow pitfalls (composite actions, ref caching, permissions) | `references/reusable-workflow-pitfalls.md` |
| Org-level security settings (SHA pinning) | `references/org-security-settings.md` |
| Tag validation (defense-in-depth) | `references/tag-validation.md` |
| AI reviewer pushback patterns | `references/ai-reviewer-pushback.md` |
| Agentic workflows | `references/agentic-workflows.md` |

---

> **Contributing:** https://github.com/netresearch/github-project-skill
