# actionlint - GitHub Actions Workflow Linter

Static analysis tool for GitHub Actions workflow files. Catches syntax errors, type mismatches, deprecated features, and security issues before pushing to CI.

**Repository:** https://github.com/rhysd/actionlint

## Installation

```bash
# Go install
go install github.com/rhysd/actionlint/cmd/actionlint@latest

# Homebrew
brew install actionlint

# Download binary (Linux)
curl -sL https://github.com/rhysd/actionlint/releases/latest/download/actionlint_linux_amd64.tar.gz | tar xz -C /usr/local/bin actionlint

# Docker
docker run --rm -v "$(pwd):/repo" -w /repo rhysd/actionlint:latest
```

## Command-Line Usage

```bash
# Lint all workflows in .github/workflows/
actionlint

# Lint a specific file
actionlint .github/workflows/ci.yml

# Colored output (auto-detects terminal)
actionlint -color

# JSON output (for CI pipelines and editors)
actionlint -format '{{json .}}'

# SARIF output (for GitHub Code Scanning)
actionlint -format sarif > actionlint.sarif

# Verbose output (shows checked files)
actionlint -verbose

# Ignore specific rules
actionlint -ignore 'SC2086'           # Ignore shellcheck rule
actionlint -ignore 'label "self-hosted"'  # Ignore runner label warning

# Specify shellcheck binary path
actionlint -shellcheck /usr/local/bin/shellcheck

# Disable shellcheck integration
actionlint -shellcheck=

# Disable pyflakes integration
actionlint -pyflakes=

# Stdin mode (pipe workflow content)
cat .github/workflows/ci.yml | actionlint -stdin-filename ci.yml -
```

## Flag Reference

| Flag | Description |
|------|-------------|
| `-color` | Force colored output |
| `-no-color` | Disable colored output |
| `-format <template>` | Custom output format (Go template) |
| `-ignore <pattern>` | Regex pattern for errors to ignore (repeatable) |
| `-shellcheck <path>` | Path to shellcheck binary (empty to disable) |
| `-pyflakes <path>` | Path to pyflakes binary (empty to disable) |
| `-stdin-filename <name>` | Filename for stdin input |
| `-verbose` | Show verbose output |
| `-debug` | Show debug output |
| `-oneline` | One-line compact output |
| `-config-file <path>` | Path to configuration file |

## Configuration File

Create `.github/actionlint.yaml` in the repository root (auto-detected):

```yaml
# .github/actionlint.yaml

# Define custom runner labels your org uses
self-hosted-runner:
  labels:
    - linux-large
    - ubuntu-24.04-16core
    - arm64

# Patterns of errors to ignore (regex)
ignore:
  # Ignore shellcheck SC2086 (double quote to prevent globbing)
  - 'SC2086'
  # Ignore specific expression warnings
  - 'label "self-hosted" is unknown'

# Configure paths (available since actionlint 1.7+)
paths:
  shellcheck: /usr/local/bin/shellcheck
  pyflakes: ""  # disable pyflakes
```

### Configuration for Common Project Types

**TYPO3 Extension:**
```yaml
self-hosted-runner:
  labels: []
ignore:
  - 'SC2086'  # phpunit commands often need unquoted vars
```

**Go Project:**
```yaml
self-hosted-runner:
  labels: []
ignore: []
```

**Monorepo with Custom Runners:**
```yaml
self-hosted-runner:
  labels:
    - linux-large
    - gpu-runner
    - arm64-builder
ignore:
  - 'label "linux-large" is unknown'
```

## Common Error Codes and Fixes

### Expression Syntax Errors

```
Error: unexpected token "}" while parsing
```
**Cause:** Malformed `${{ }}` expression.
**Fix:** Check for unbalanced braces, missing operators, or invalid function calls.

```yaml
# Bad
if: ${{ github.event_name == 'push' && }}

# Good
if: ${{ github.event_name == 'push' }}
```

### Undefined Action Inputs/Outputs

```
Error: input "node-versions" is not defined in action "actions/setup-node@v4"
```
**Cause:** Typo in action input name.
**Fix:** Check the action's `action.yml` for correct input names.

```yaml
# Bad
- uses: actions/setup-node@v4
  with:
    node-versions: '22'  # wrong: plural

# Good
- uses: actions/setup-node@v4
  with:
    node-version: '22'   # correct: singular
```

### YAML Type Errors

```
Error: "permissions" section should be mapping
```
**Cause:** Wrong YAML structure for permissions block.
**Fix:** Use mapping syntax, not sequence.

```yaml
# Bad
permissions:
  - contents: read

# Good
permissions:
  contents: read
```

### Deprecated Action Versions

```
Error: the runner of "ubuntu-18.04" is no longer supported
```
**Cause:** Using a deprecated runner image.
**Fix:** Update to a supported runner version.

```yaml
# Bad
runs-on: ubuntu-18.04

# Good
runs-on: ubuntu-24.04
```

### Missing Permissions Declarations

actionlint checks that workflow-level or job-level `permissions` are set when using `GITHUB_TOKEN`. This aligns with the principle of least privilege.

```yaml
# Add explicit permissions
permissions:
  contents: read
  pull-requests: write
```

### ShellCheck Issues in run: Blocks

```
Error: shellcheck reported issue in this script: SC2086
```
**Cause:** ShellCheck found an issue in a `run:` block. actionlint embeds shellcheck analysis for bash/sh scripts.
**Fix:** Follow the shellcheck recommendation, or ignore with inline directive.

```yaml
# Fix: quote the variable
- run: echo "$MY_VAR"

# Or ignore inline (not recommended)
- run: |
    # shellcheck disable=SC2086
    echo $MY_VAR
```

### Context/Object Property Access

```
Error: property "conclusion" is not defined in object type "steps"
```
**Cause:** Accessing a step output without using the step ID.
**Fix:** Use `steps.<step-id>.outputs.<name>` or `steps.<step-id>.conclusion`.

```yaml
steps:
  - id: build
    run: echo "done"
  - if: steps.build.conclusion == 'success'
    run: echo "Build succeeded"
```

## ShellCheck Integration

actionlint embeds [ShellCheck](https://www.shellcheck.net/) to analyze shell scripts in `run:` blocks. This provides:

- Variable quoting warnings (SC2086)
- Unused variable detection (SC2034)
- Command injection risks (SC2091)
- Bash-specific syntax issues

**How it works:**
1. actionlint extracts `run:` block content
2. Detects shell type from `shell:` key (defaults to `bash`)
3. Runs shellcheck on the extracted script
4. Maps errors back to workflow file line numbers

**Controlling shellcheck rules:**

```yaml
# Per-block: use shellcheck directives
- run: |
    # shellcheck disable=SC2086,SC2034
    echo $UNQUOTED_VAR

# Globally: ignore in actionlint config
# .github/actionlint.yaml
ignore:
  - 'SC2086'

# Disable shellcheck entirely
# Run: actionlint -shellcheck=
```

**Common shellcheck rules in workflows:**

| Rule | Description | Fix |
|------|-------------|-----|
| SC2086 | Double quote to prevent globbing | `"$VAR"` instead of `$VAR` |
| SC2034 | Variable appears unused | Remove or export the variable |
| SC2046 | Quote to prevent word splitting | `"$(command)"` instead of `$(command)` |
| SC2129 | Use `>> file` grouped, not repeated | Group multiple appends |
| SC2155 | Declare and assign separately | `local var; var=$(cmd)` |

## Pre-commit Hook Integration

### Using pre-commit framework

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/rhysd/actionlint
    rev: v1.7.11  # check for latest version
    hooks:
      - id: actionlint
```

### Manual git hook

```bash
#!/usr/bin/env bash
# .git/hooks/pre-commit

# Check if any workflow files are staged
WORKFLOW_FILES=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.github/workflows/.*\.ya?ml$')

if [ -n "$WORKFLOW_FILES" ]; then
    echo "Running actionlint on modified workflows..."
    echo "$WORKFLOW_FILES" | xargs actionlint
    if [ $? -ne 0 ]; then
        echo "actionlint failed. Fix errors before committing."
        exit 1
    fi
fi
```

## CI Integration Patterns

### Direct Run in CI

```yaml
name: Lint Workflows
on:
  pull_request:
    paths:
      - '.github/workflows/**'

jobs:
  actionlint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install actionlint
        run: |
          curl -sL https://github.com/rhysd/actionlint/releases/latest/download/actionlint_linux_amd64.tar.gz \
            | tar xz -C /usr/local/bin actionlint
      - name: Run actionlint
        run: actionlint -color
```

### With reviewdog (Inline PR Comments)

```yaml
name: Lint Workflows
on:
  pull_request:
    paths:
      - '.github/workflows/**'

permissions:
  contents: read
  pull-requests: write

jobs:
  actionlint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: reviewdog/action-actionlint@v1
        with:
          fail_level: error
          reporter: github-pr-review  # inline comments on PR
```

**Important:** Always set `fail_level: error` with reviewdog. Without it, actionlint warnings appear as annotations but do not fail the check, allowing broken workflows to be merged.

### SARIF Upload (GitHub Code Scanning)

```yaml
name: Lint Workflows
on:
  push:
    branches: [main]
  pull_request:
    paths:
      - '.github/workflows/**'

permissions:
  contents: read
  security-events: write

jobs:
  actionlint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install actionlint
        run: |
          curl -sL https://github.com/rhysd/actionlint/releases/latest/download/actionlint_linux_amd64.tar.gz \
            | tar xz -C /usr/local/bin actionlint
      - name: Run actionlint (SARIF)
        run: actionlint -format sarif > actionlint.sarif
        continue-on-error: true
      - uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: actionlint.sarif
```

### Combined with Other Linters

```yaml
name: CI Quality
on: [pull_request]

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # Lint workflows
      - name: actionlint
        run: |
          curl -sL https://github.com/rhysd/actionlint/releases/latest/download/actionlint_linux_amd64.tar.gz \
            | tar xz -C /usr/local/bin actionlint
          actionlint -color

      # Lint Dockerfiles
      - uses: hadolint/hadolint-action@v3.1.0
        with:
          dockerfile: Dockerfile

      # Lint shell scripts
      - name: shellcheck
        run: shellcheck scripts/*.sh
```

## Editor Integration

- **VS Code:** Install [actionlint extension](https://marketplace.visualstudio.com/items?itemName=arahata.linter-actionlint) for real-time feedback
- **Vim/Neovim:** Use with ALE or null-ls for inline diagnostics
- **JetBrains:** Configure as external tool with file watcher on `*.yml` in `.github/workflows/`

## Troubleshooting

### "shellcheck is not installed"
actionlint optionally uses shellcheck. Install it or disable with `actionlint -shellcheck=`.

### False positives on reusable workflows
Reusable workflow inputs/outputs may not be fully validated. Use `-ignore` for known false positives.

### Custom actions not recognized
actionlint cannot resolve local actions (`./`) or private actions at lint time. Ignore with:
```yaml
# .github/actionlint.yaml
ignore:
  - 'could not read action'
```

### Large matrix expressions
Complex matrix expressions with `fromJSON()` may cause type-check warnings. These are usually safe to ignore:
```yaml
ignore:
  - 'fromJSON'
```

### yamllint `empty-lines` rejects trailing blank lines

Unrelated to actionlint itself, but bites right next to it in CI: if you run `yamllint` in the same lane, its default `empty-lines` rule rejects a file that ends with more than one newline. Workflow files end with exactly one newline.

Generators that use `echo "$CONTENT" > file.yml` frequently add a trailing blank; prefer:

```bash
printf '%s\n' "$CONTENT" > file.yml
```

Verify after writing:

```bash
# Bytes at end of file — should be `0a` (one newline), not `0a0a`.
tail -c 2 file.yml | xxd -p
```
