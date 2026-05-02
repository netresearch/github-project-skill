# Architecture Overview

## Purpose

The github-project-skill is an Agent Skill package that provides GitHub platform configuration knowledge to AI agents (Claude Code, Cursor, GitHub Copilot, and other skills-compatible agents).

## Skill Structure

```
skills/github-project/
├── SKILL.md              # Skill entry point — loaded by agents at activation
├── checkpoints.yaml      # Verification checkpoints for skill validation
├── evals/evals.json      # Evaluation test cases
├── references/           # Deep-dive reference documents (linked from SKILL.md/README)
├── assets/               # Workflow and config templates (*.template files)
└── scripts/              # verify-github-project.sh — checks a repo's GH config
```

## How It Works

1. **Agent activation**: An AI agent loads `SKILL.md` when GitHub project configuration tasks are detected (PR merge issues, branch protection, auto-merge, etc.).
2. **Knowledge delivery**: SKILL.md contains quick diagnostics and decision trees. For deeper topics, it references files in `references/`.
3. **Templates**: The `assets/` directory provides copy-paste workflow templates (auto-merge variants, PR quality gates, issue templates, etc.).
4. **Verification**: `scripts/verify-github-project.sh` audits a target repository against recommended GitHub project standards.

## Distribution Channels

- **Composer**: `netresearch/github-project-skill` via `composer.json` (requires `composer-agent-skill-plugin`)
- **npm**: `github:netresearch/github-project-skill` via `package.json` (requires `@netresearch/agent-skill-coordinator`, which discovers the skill in `node_modules` and registers it in `AGENTS.md` via a `postinstall` hook)
- **Claude Code plugin**: `.claude-plugin/plugin.json` for marketplace distribution
- **npx / skills.sh**: Direct install via `npx skills add`
- **Git clone / release download**: Manual installation

When making changes to release or distribution logic, all five channels must be considered. The npm channel ships from a `package.json` allowlist (`files: ["skills/github-project/", LICENSE files, README.md]`) — anything outside that allowlist is invisible to npm consumers.

## Key Design Decisions

- **Platform-only scope**: This skill handles GitHub platform features. CI/CD content, language tooling, and security scanning are delegated to dedicated skills.
- **Three auto-merge patterns**: Merge queue (GraphQL), branch protection (`--auto`), and direct merge each have separate templates because they require fundamentally different GitHub API interactions.
- **GraphQL for thread resolution**: GitHub REST API and `gh` CLI lack PR review thread resolution support, so the skill teaches GraphQL mutations.
- **Split licensing**: Code (MIT) and content (CC-BY-SA-4.0) are licensed separately to allow flexible reuse.
