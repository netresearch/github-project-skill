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

- **After `gh repo create`, before first commit/PR** — apply branch protection (REQUIRED, see below)
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

## Required First Step After `gh repo create`

After creating any new Netresearch repository, **before pushing the first commit or opening the first PR**, you MUST apply branch protection. Without this, the unresolved-threads workflow rule is unenforceable — operator discipline alone has demonstrably failed (see [snipe-it-docker-compose-stack#17](https://github.com/netresearch/snipe-it-docker-compose-stack/pull/17): 3 of 8 merged PRs shipped unresolved bot-reviewer threads, including a HIGH-severity token leak that both Copilot and gemini-code-assist had flagged).

Two-step flow:

```bash
# 1. Immediately after `gh repo create` and the first push:
bash <skill-root>/skills/github-project/scripts/init-branch-protection.sh OWNER/REPO
#    Applies: required_conversation_resolution=true, 1 approver,
#             no force-push, no deletions, no required checks yet.

# 2. After the first CI run completes on the default branch:
bash <skill-root>/skills/github-project/scripts/init-branch-protection.sh OWNER/REPO --from-current-checks
#    Captures the now-known check-run names as required status contexts
#    with strict=true.
```

The script is idempotent: re-running on an already-compliant repo reports `already compliant` and exits 0. Drift on opinionated fields exits 1 with a per-field diff (no silent clobber of admin choices).

Baseline applied is intentionally minimal — `enforce_admins` and `required_signatures` are NOT in the template (per-repo decision; tighten via the one-liners in the script header). The load-bearing field is `required_conversation_resolution: true`, which is what makes the "abort merge if unresolved threads" memory rule structurally safe rather than discipline-dependent.

You can also invoke `/assess github-project` against a repo to verify (read-only) that the baseline is in place — checkpoint `GH-31` fails with `severity: error` if `required_conversation_resolution` is not enabled.

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
# REQUIRED baseline (one-liner): is required_conversation_resolution on?
gh api repos/OWNER/REPO/branches/$(gh api repos/OWNER/REPO --jq .default_branch)/protection \
  --jq '.required_conversation_resolution.enabled // false'
# If false, run scripts/init-branch-protection.sh OWNER/REPO

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
# Apply baseline branch protection to a new repo (REQUIRED post-`gh repo create`)
scripts/init-branch-protection.sh OWNER/REPO
# After first CI run completes:
scripts/init-branch-protection.sh OWNER/REPO --from-current-checks

# Audit an existing local checkout against GitHub-platform best practices
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
