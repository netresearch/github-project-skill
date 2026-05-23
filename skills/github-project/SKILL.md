---
name: github-project
description: "Use when bootstrapping a repo (apply branch protection before first PR), PRs won't merge or BLOCKED, AI reviewer pushback, auto-merge fails for Dependabot/Renovate, branch protection or rulesets, CI fails, authoring reusable workflows, harden-runner, or CODEOWNERS/PR templates."
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

- **Post `gh repo create` + initial push, before first PR** — apply branch protection (REQUIRED, see below)
- PR won't merge, BLOCKED, or unresolved threads
- Auto-merge fails for Dependabot/Renovate
- Solo maintainer auto-approve
- Branch protection, rulesets, `enforce_admins`
- GHA failures or permission issues
- Signed commit merge (rebase can't auto-sign)
- CodeQL default vs custom workflows
- Scorecard (token perms, pinned deps)
- CODEOWNERS, templates, release labels
- Fork PR merge base

> **REQUIRED post `gh repo create`:** `scripts/init-branch-protection.sh OWNER/REPO` — see `references/repo-bootstrap.md` (closes [snipe-it#17](https://github.com/netresearch/snipe-it-docker-compose-stack/pull/17) class).

## Quick Diagnostics

### PR Won't Merge

```bash
gh pr view PR --repo OWNER/REPO \
  --json mergeStateStatus,reviewDecision,mergeable,reviewThreads
```

### Solo Maintainer: PRs Stuck on REVIEW_REQUIRED

Use `assets/pr-quality.yml.template` for auto-approve with `required_approving_review_count >= 1`.

### Auto-merge Setup

Requires `allow_auto_merge`, `pull_request_target` trigger, `user.login` bot detection, `gh pr merge --auto` with dynamic strategy. See `references/auto-merge-guide.md`.

### Auto-merge Not Working

```bash
gh pr view PR --repo OWNER/REPO --json autoMergeRequest --jq .autoMergeRequest
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
gh api repos/OWNER/REPO/branches/main/protection \
  --jq '{rcr: .required_conversation_resolution.enabled, admins: .enforce_admins.enabled}'
gh api repos/OWNER/REPO/code-scanning/default-setup --jq '.state'
gh pr view PR --repo OWNER/REPO --json reviewThreads --jq '.reviewThreads'
```

### Merge Strategy Issues

See `references/auto-merge-guide.md` (signed-commit rebase fixes, workflow-file PRs, Copilot auto-approve race).

## Running Scripts

```bash
scripts/init-branch-protection.sh OWNER/REPO              # baseline (post gh repo create)
scripts/init-branch-protection.sh OWNER/REPO --from-current-checks   # after first CI
scripts/verify-github-project.sh /path/to/repository      # local-checkout audit
```

## References

| Topic | Reference |
|-------|-----------|
| Repo bootstrap (post `gh repo create`) | `references/repo-bootstrap.md` |
| Repository file layout | `references/repository-structure.md` |
| Branch migration | `references/branch-migration.md` |
| Dependabot/Renovate | `references/dependency-management.md` |
| Auto-approve + auto-merge | `references/auto-merge-guide.md` |
| Merge strategy (signed commits) | `references/merge-strategy.md` |
| Sub-issues | `references/sub-issues.md` |
| Release labeling | `references/release-labeling.md` |
| gh CLI commands | `references/gh-cli-reference.md` |
| Polyglot CI checklists | `references/repo-setup-guide.md` |
| Scorecard, CodeQL, security | `references/security-config.md` |
| actionlint | `references/actionlint-guide.md` |
| Workflow bash pitfalls | `references/workflow-bash-patterns.md` |
| Fork merge base | `references/pr-commit-cleanup.md` |
| Multi-repo batch ops | `references/multi-repo-operations.md` |
| Reusable workflow security | `references/reusable-workflow-security.md` |
| Reusable workflow pitfalls | `references/reusable-workflow-pitfalls.md` |
| Org security settings | `references/org-security-settings.md` |
| Tag validation | `references/tag-validation.md` |
| AI reviewer pushback | `references/ai-reviewer-pushback.md` |
| Agentic workflows | `references/agentic-workflows.md` |

---

> Contributing: https://github.com/netresearch/github-project-skill
