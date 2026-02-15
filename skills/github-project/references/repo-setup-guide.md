# Repository Setup Guide

Project-type-specific CI checklists and repository standards.

## Go Project CI Checklist

| Setting | Purpose | How |
|---------|---------|-----|
| Branch protection | Require tests pass before merge | Branch settings or Rulesets |
| Dependabot/Renovate | Automated dependency updates | `.github/dependabot.yml` or `renovate.json` |
| Auto-merge workflow | Merge minor/patch updates automatically | `assets/auto-merge*.yml` templates |
| Required checks | CI workflow names in branch protection | Match exact workflow job names |

## Polyglot Project CI Checklist (PHP + JavaScript)

| Requirement | Implementation | Why |
|-------------|----------------|-----|
| PHP test coverage | `phpunit --coverage-clover` for each test suite | Codecov needs all suites |
| JavaScript test coverage | `npm run test:coverage` with lcov output | Codecov aggregates all languages |
| vitest lcov reporter | `reporter: ['text', 'json', 'html', 'lcov']` | Required for Codecov compatibility |
| Codecov upload | List ALL coverage files in `files:` parameter | Ensures complete coverage picture |

### Example CI Configuration

```yaml
# Run all PHP test suites with coverage
- run: php -d pcov.enabled=1 .Build/bin/phpunit -c Build/phpunit/UnitTests.xml --coverage-clover .Build/coverage/unit.xml
- run: php -d pcov.enabled=1 .Build/bin/phpunit -c Build/phpunit/IntegrationTests.xml --coverage-clover .Build/coverage/integration.xml

# Run JavaScript tests with coverage
- uses: actions/setup-node@SHA # vX.Y.Z
  with:
    node-version: '22'
- run: npm install
- run: npm run test:coverage

# Upload ALL coverage files
- uses: codecov/codecov-action@SHA # vX.Y.Z
  with:
    files: .Build/coverage/unit.xml,.Build/coverage/integration.xml,coverage/lcov.info
```

### vitest Configuration

When using vitest, the `lcov` reporter is **required** for Codecov:

```javascript
// vitest.config.js
coverage: {
    provider: 'v8',
    reporter: ['text', 'json', 'html', 'lcov'],  // lcov REQUIRED
    reportsDirectory: 'coverage',
}
```

## TYPO3 Extension Repository Standards

### Repository Settings

Configure via GitHub UI or `gh` CLI:

```bash
# Enable Projects tab
gh repo edit --enable-projects

# Set description (template)
gh repo edit --description "TYPO3 extension for <purpose> - by Netresearch"

# Add topics
gh api repos/OWNER/REPO/topics -X PUT -f names='["typo3","typo3-extension","php","<domain-topics>"]'
```

| Setting | Value | Why |
|---------|-------|-----|
| `has_projects` | true | Project board for issue tracking |
| `has_wiki` | false | Use Documentation/ folder instead |
| Description | `<What it does> - by Netresearch` | Consistent branding |

### Required Topics

All TYPO3 extension repos MUST have these topics:

| Topic | Required | Example |
|-------|----------|---------|
| `typo3` | Always | - |
| `typo3-extension` | Always | - |
| `php` | Always | - |
| Domain-specific | 2-5 more | `ckeditor`, `llm`, `ai`, `rte` |

**Example from t3x-rte_ckeditor_image:**
```
typo3, typo3-extension, typo3cms-extension, ckeditor, ckeditor-plugin, rte-ckeditor, magic-images
```

**Example from t3x-nr-llm:**
```
typo3, typo3-extension, php, ai, llm, openai, anthropic, claude, gemini, gpt
```

### README Badge Order

Badges should appear in this order (see `netresearch-branding` skill for templates):

```markdown
<!-- Row 1: CI/Quality badges -->
[![CI](...)][ci]
[![codecov](...)][codecov]
[![Documentation](...)][docs]  <!-- if applicable -->

<!-- Row 2: Security badges -->
[![OpenSSF Scorecard](...)][scorecard]
[![OpenSSF Best Practices](...)][bestpractices]
[![SLSA 3](...)][slsa]

<!-- Row 3: Standards badges -->
[![PHPStan](...)][phpstan]
[![PHP 8.x+](...)][php]
[![TYPO3 vXX](...)][typo3]
[![License](...)][license]
[![Latest Release](...)][release]
[![Contributor Covenant](...)][covenant]

<!-- Row 4: TYPO3 TER badges (if published to TER) -->
![Composer](https://typo3-badges.dev/badge/EXT_KEY/composer/shields.svg)
![Downloads](https://typo3-badges.dev/badge/EXT_KEY/downloads/shields.svg)
![Extension](https://typo3-badges.dev/badge/EXT_KEY/extension/shields.svg)
![Stability](https://typo3-badges.dev/badge/EXT_KEY/stability/shields.svg)
![TYPO3](https://typo3-badges.dev/badge/EXT_KEY/typo3/shields.svg)
![Version](https://typo3-badges.dev/badge/EXT_KEY/version/shields.svg)
```

### Quick Setup Commands

```bash
# Set topics for TYPO3 extension
gh api repos/netresearch/t3x-EXTNAME/topics -X PUT \
  -f names='["typo3","typo3-extension","php","DOMAIN1","DOMAIN2"]'

# Enable projects
gh repo edit netresearch/t3x-EXTNAME --enable-projects

# Update description
gh repo edit netresearch/t3x-EXTNAME \
  --description "TYPO3 extension for PURPOSE - by Netresearch"
```

### Verification

Check repository compliance:

```bash
# Check topics
gh api repos/OWNER/REPO/topics --jq 'if (.names | contains(["typo3"]) and contains(["typo3-extension"]) and contains(["php"])) then "OK: Required topics present" else "MISSING: Required topics" end'

# Check has_projects
gh api repos/OWNER/REPO --jq 'if .has_projects then "OK: Projects enabled" else "MISSING: Projects disabled" end'
```
