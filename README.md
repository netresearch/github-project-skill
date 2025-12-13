# GitHub Project Skill

A Claude Code skill for GitHub repository setup and platform-specific features.

## What This Skill Does

This skill provides patterns and workflows for configuring GitHub-specific features:

- **Branch Protection**: Configure rules for `main` branch via CLI
- **PR Workflows**: Enforce conversation resolution, reviewer assignment
- **CODEOWNERS**: Automatic reviewer assignment based on file paths
- **Issues & Discussions**: Templates, labels, and category setup
- **Dependabot/Renovate**: Auto-merge workflows for dependency updates
- **GitHub Releases**: Automatic release notes configuration

## Scope

This skill focuses **exclusively on GitHub platform features**. For other concerns:

| Need | Use Skill |
|------|-----------|
| CI/CD pipelines | `go-development`, `php-modernization` |
| Security scanning | `security-audit` |
| SLSA, SBOMs | `enterprise-readiness` |
| Git branching, conventional commits | `git-workflow` |

## Installation

### Via Claude Code Marketplace

```bash
claude mcp add-plugin netresearch/github-project-skill
```

### Manual Installation

1. Clone this repository
2. Add to your Claude Code configuration

## Usage

The skill activates automatically when you:

- Create a new GitHub repository
- Ask to "check my GitHub project setup"
- Configure branch protection
- Set up GitHub Issues/Discussions
- Configure auto-merge for Dependabot/Renovate

### Verification Script

Check your project configuration:

```bash
./scripts/verify-github-project.sh /path/to/your/repo
```

## Contents

```
github-project-skill/
├── SKILL.md                          # Main skill instructions
├── references/
│   ├── dependency-management.md      # Dependabot/Renovate patterns
│   └── repository-structure.md       # Standard repo files
├── scripts/
│   └── verify-github-project.sh      # Configuration checker
└── templates/
    ├── auto-merge.yml.template       # GitHub Actions auto-merge
    ├── dependabot.yml.template       # Dependabot configuration
    ├── renovate.json.template        # Renovate configuration
    ├── bug_report.md.template        # Issue template
    ├── feature_request.md.template   # Issue template
    ├── PULL_REQUEST_TEMPLATE.md.template
    ├── CODEOWNERS.template
    ├── CONTRIBUTING.md.template
    └── SECURITY.md.template
```

## License

MIT License - see [LICENSE](LICENSE)

## Author

[Netresearch DTT GmbH](https://www.netresearch.de)
