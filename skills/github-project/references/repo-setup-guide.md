<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

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

## SonarCloud Quality Gate Gotcha

A **wholesale structural change** to a file (e.g. converting a classic-script IIFE to an
ES module, or moving most of a class) makes SonarCloud attribute the **entire file** as
"new code". Every latent smell in it then counts against the new-code gate, so
`new_maintainability_rating` can flip to D from a change that "only refactored" — and the
gate blocks the merge.

Anticipate it: when you modernise a file's module structure, **fix all its latent smells
in the same change** rather than reverting — typically `var`→`const` (rule S3504), reduce
cognitive complexity by extracting helpers (S3776), and replace `innerHTML` with DOM
construction / `DOMParser` (also clears the XSS hotspot). The gate sees a brand-new file,
not a diff.

For Python, pre-check S3776 locally before pushing: `uvx --from complexipy complexipy
<file>` prints the cognitive complexity per function. The rule's default threshold is
15; a project's quality profile can change it, so read the profile assigned to the
project. complexipy is an independent tool, not SonarCloud's analyzer. On
`netresearch/data-tools-skill` its figures matched SonarCloud's for three functions
(18, 17 and 16, and 2 and 3 after a split), so a local run can save a push and a
re-analysis per attempt; SonarCloud's result on the PR stays the authority.

To raise one rule's threshold for one project, give the project its own quality profile
that inherits the profile it uses now, and override only that rule. The token needs the
organization's `Administer Quality Profiles` permission: `qualityprofiles/search?organization=<org>`
answers `"actions":{"create":true}` when it has it. Assigning the profile to a project also
works with the project's `Administer` permission. Four `POST` calls to
`https://sonarcloud.io/api/qualityprofiles/…`, each with `Authorization: Bearer <token>`:

1. `create` with `name`, `language` and `organization`. The new key is in `.profile.key`.
2. `change_parent` with `key=<new key>` and `parentKey=<key of the current profile>` and
   nothing else. With `organization`, `language` or `qualityProfile` added, the call
   answers HTTP 400: "When a quality profile key is set, 'organization' 'language' and
   'qualityProfile' can't be set".
3. `activate_rule` with `key=<new key>`, `rule=<rule>` and `params=<param>=<value>`, for
   example `rule=php:S1142` and `params=max=9`.
4. `add_project` with `key=<new key>` and `project=<projectKey>`.

Read the result back from `qualityprofiles/search?project=<projectKey>&organization=<org>`,
which lists `parentKey`. `qualityprofiles/show` returns `parentKey: null` for a profile
that has a parent, so it cannot confirm step 2. In
`rules/show?key=<rule>&organization=<org>&actives=true` the override carries
`inherit: OVERRIDES`. The next analysis of the branch closes the issues that the new
threshold no longer raises; issues above the new threshold stay open.
(`netresearch/t3x-nr-llm`, 2026-10-25: `php:S1142` from 3 to 9 returns; after the 22
methods above 9 were split, `main` went from 278 issues of that rule to 0.)

To see which new-code smells are blocking, query SonarCloud's `api/issues/search`
endpoint (authenticated with your SonarCloud token via HTTP basic auth — token as the
username, empty password) filtered to `types=CODE_SMELL&resolved=false` for the PR, e.g.:

```
GET https://sonarcloud.io/api/issues/search
      ?componentKeys=<projectKey>&pullRequest=<PR>&types=CODE_SMELL&resolved=false
      &s=SEVERITY&asc=false
```

Each issue's `rule` + `message` + `component:line` tells you exactly what to fix.
