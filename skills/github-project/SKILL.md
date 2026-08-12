---
name: github-project
description: "Use when bootstrapping a repo (apply branch protection before first PR), PRs won't merge or BLOCKED, AI reviewer pushback, auto-merge fails for Dependabot/Renovate, branch protection or rulesets, CI fails, authoring or consuming reusable workflows, editing a repo's own .github/workflows, harden-runner, or CODEOWNERS/PR templates."
license: "(MIT AND CC-BY-SA-4.0). See LICENSE-MIT and LICENSE-CC-BY-SA-4.0"
compatibility: "Requires gh CLI, git."
metadata:
  author: Netresearch DTT GmbH
  version: "2.16.1"
  repository: https://github.com/netresearch/github-project-skill
allowed-tools: Bash(gh:*) Bash(git:*) Bash(grep:*) Read Write
---

# GitHub Project Skill

## When to Use

- **Post `gh repo create` + push, before first PR** — REQUIRED: `scripts/init-branch-protection.sh OWNER/REPO` (`references/repo-bootstrap.md`)
- Adding a job to a repo's workflow — see pitfall #6
- PR won't merge / threads
- Auto-merge fails (Dependabot/Renovate)
- Solo auto-approve
- Branch protection, rulesets
- GHA failures
- Signed-commit merge
- CodeQL
- Scorecard
- CODEOWNERS, templates, labels
- Fork PR merge base

## Quick Diagnostics

### PR Won't Merge

```bash
gh pr view PR --repo OWNER/REPO \
  --json mergeStateStatus,reviewDecision,mergeable,reviewThreads
```

### Solo Maintainer: PRs Stuck on REVIEW_REQUIRED

Use `assets/pr-quality.yml.template` for auto-approve with `required_approving_review_count >= 1`.

### Auto-merge Setup

Requires `allow_auto_merge`, `pull_request_target`, bot detection, `gh pr merge --auto`. See `references/auto-merge-guide.md`.

### Auto-merge Not Working

```bash
gh pr view PR --repo OWNER/REPO --json autoMergeRequest --jq .autoMergeRequest
```

Bypass actors: `references/security-config.md`.

### GitHub Actions Failing

```bash
gh run list --repo OWNER/REPO --limit 5
gh run view RUN_ID --repo OWNER/REPO --log-failed
gh run rerun RUN_ID --repo OWNER/REPO
```

### Security & Compliance Quick Checks

```bash
gh api repos/OWNER/REPO/rules/branches/main
gh api repos/OWNER/REPO/branches/main/protection \
  --jq '{rcr: .required_conversation_resolution.enabled, admins: .enforce_admins.enabled}'
gh api repos/OWNER/REPO/code-scanning/default-setup --jq '.state'
gh pr view PR --repo OWNER/REPO --json reviewThreads --jq '.reviewThreads'
```

### Merge Strategy Issues

See `references/auto-merge-guide.md` (signed-commit rebase, workflow-file PRs, Copilot race).

## Running Scripts

```bash
scripts/init-branch-protection.sh OWNER/REPO              # baseline (post gh repo create)
scripts/init-branch-protection.sh OWNER/REPO --from-current-checks   # after first CI
scripts/verify-github-project.sh /path/to/repository      # local-checkout audit
```

## No editorializing

State what a change does, not how good it is. See `references/no-editorializing.md`.

## References

| Topic | Reference |
|-------|-----------|
| Repo bootstrap | `references/repo-bootstrap.md` |
| Repository file layout | `references/repository-structure.md` |
| Branch migration | `references/branch-migration.md` |
| Dependabot/Renovate | `references/dependency-management.md` |
| Auto-approve + auto-merge | `references/auto-merge-guide.md` |
| Merge strategy | `references/merge-strategy.md` |
| Sub-issues | `references/sub-issues.md` |
| Release labeling | `references/release-labeling.md` |
| gh CLI commands | `references/gh-cli-reference.md` |
| Polyglot CI checklists | `references/repo-setup-guide.md` |
| Scorecard, CodeQL, security | `references/security-config.md` |
| actionlint | `references/actionlint-guide.md` |
| Workflow bash pitfalls | `references/workflow-bash-patterns.md` |
| Runner capacity | `references/ci-runner-capacity.md` |
| No editorializing | `references/no-editorializing.md` |
| Fork merge base | `references/pr-commit-cleanup.md` |
| Multi-repo batch ops | `references/multi-repo-operations.md` |
| Cross-repo references | `references/cross-repo-references.md` |
| Reusable workflow security | `references/reusable-workflow-security.md` |
| Reusable workflow pitfalls | `references/reusable-workflow-pitfalls.md` |
| Org security settings | `references/org-security-settings.md` |
| Tag validation | `references/tag-validation.md` |
| AI reviewer pushback | `references/ai-reviewer-pushback.md` |
| Agentic workflows | `references/agentic-workflows.md` |
| Pages + data collectors | `references/pages-and-collector-workflows.md` |

---

> Contributing: https://github.com/netresearch/github-project-skill
