# GitHub Project Skill

<!-- Index file — detail lives in docs/ and skills/. Keep under 100 lines. -->

## Repo Structure

- `skills/github-project/` — Skill definition (SKILL.md), checkpoints, evals
- `skills/github-project/references/` — Detailed reference docs (merge strategy, sub-issues, branch migration, etc.)
- `skills/github-project/assets/` — Templates (auto-merge workflows, PR templates, CODEOWNERS, etc.)
- `skills/github-project/scripts/` — `verify-github-project.sh` verification script
- `.github/workflows/` — CI (lint, release, auto-merge-deps)
- `.claude-plugin/` — Plugin manifest for Claude Code marketplace
- `Build/` — Build scripts and git hooks
- `docs/` — Architecture and execution plans

## Scope

This skill covers **GitHub platform configuration only**:

- Branch protection rules and GitHub Rulesets
- CODEOWNERS configuration
- GitHub Issues, Discussions, Projects, sub-issues
- Dependabot/Renovate auto-merge (including merge queue GraphQL)
- PR review thread resolution (GraphQL API)
- Repository settings and release configuration
- Master-to-main branch migration

**Delegated to other skills:**

- CI/CD pipelines: `go-development`, `php-modernization`, `typo3-testing`
- Security scanning (CodeQL, gosec): `security-audit`
- SLSA, SBOMs, supply chain: `enterprise-readiness`
- Git branching, conventional commits: `git-workflow`

## Commands

```bash
# Lint (CI uses reusable workflow from skill-repo-skill)
# No local lint target — validation runs in GitHub Actions

# Verify a target repo's GitHub project setup
./skills/github-project/scripts/verify-github-project.sh /path/to/repo

# Check plugin version consistency
./Build/Scripts/check-plugin-version.sh
```

## Key Patterns

- Auto-merge has three variants: branch-protection (`--auto`), merge-queue (GraphQL `enqueuePullRequest`), direct (no protection)
- PR thread resolution requires GraphQL API — `gh` CLI does not support it
- Rulesets `allowed_merge_methods` must match repo-level merge settings
- Sub-issues use GraphQL `addSubIssue` mutation (up to 8 levels, 100 per parent)

## References

- `skills/github-project/references/auto-merge-guide.md` — Auto-merge setup patterns
- `skills/github-project/references/merge-strategy.md` — Merge method alignment
- `skills/github-project/references/sub-issues.md` — Sub-issues GraphQL API
- `skills/github-project/references/branch-migration.md` — Master to main migration
- `skills/github-project/references/repository-structure.md` — Standard repo layout
- `skills/github-project/references/dependency-management.md` — Dependabot/Renovate config
- `skills/github-project/references/gh-cli-reference.md` — GitHub CLI patterns
- `skills/github-project/references/actionlint-guide.md` — Workflow linting
- `skills/github-project/references/pr-commit-cleanup.md` — PR commit hygiene
- `skills/github-project/references/reusable-workflow-security.md` — Workflow security
- `skills/github-project/references/security-config.md` — Security configuration
- `skills/github-project/references/org-security-settings.md` — Org-level security
- `skills/github-project/references/tag-validation.md` — Tag validation
- `skills/github-project/references/release-labeling.md` — Release label automation
- `skills/github-project/references/repo-setup-guide.md` — Repository setup guide
- `docs/ARCHITECTURE.md` — Architecture overview
