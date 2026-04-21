# Bash Patterns in GitHub Actions `run:` Steps

Recurring shell-scripting gotchas that turn workflow `run:` steps into silent data-loss bugs or, worse, build-passing-while-broken releases. Every entry here has caused a real incident in the netresearch fleet; fix each case up-front when you write new reusable workflows.

## Quick Index

| Symptom | Cause | See |
|---|---|---|
| Custom `::error::` never fires; step just exits non-zero with a one-line `exit` | `set -e` aborts on `VAR=$(failing-cmd)` BEFORE your diagnostic runs | [set -e + command substitution](#set--e--command-substitution) |
| Detection works for one match but "forgets" when several match | SIGPIPE race under `set -o pipefail` with early-exiting readers | [Pipefail + early readers](#pipefail--early-readers) |
| Binary has mangled version/ldflag; release log "looks fine" | `2>&1` merged stderr into a captured variable | [stderr merge contamination](#stderr-merge-contamination) |
| ldflags silently drop values; no error | Expression in top-level job `with:` evaluated BEFORE reusable checkout | [Expression context availability](#expression-context-availability) |
| Workflow runs on triggers it shouldn't, all jobs fail instantly | File failed validation — GitHub creates a failing run regardless of `on:` match | [Workflow-file validation failure](#workflow-file-validation-failure) |
| Random startup_failure across the whole fleet after a template change | Caller job permissions < reusable job's declared permissions | [Permission propagation](#permission-propagation) |

## `set -e` + command substitution

**Bug:**

```bash
set -euo pipefail

BUILD_TS=$(git show -s --format=%cI HEAD)  # fails if HEAD bad
if [[ -z "$BUILD_TS" ]]; then
  echo "::error::buildTime empty"          # never reached
  exit 1
fi
```

With `set -e`, a non-zero exit from the subshell in `$(…)` aborts the script immediately. Your custom diagnostic never runs; the user sees `Process exited with code 128` from git and is left to reverse-engineer what that means.

**Fix:** wrap in `if ! VAR=$(cmd); then`. `if` contexts are explicitly exempted from `set -e`:

```bash
if ! BUILD_TS=$(git show -s --format=%cI HEAD); then
  echo "::error::auto-build-timestamp=true but git show failed. See log."
  exit 1
fi
if [[ -z "$BUILD_TS" ]]; then
  echo "::error::git show returned exit 0 but empty output."
  exit 1
fi
```

Keep the empty-string check separately — `git show` can exit 0 and print nothing in edge cases (e.g. shallow clone with `fetch-depth: 1` on a freshly-init'd repo; note that `fetch-depth: 0` in `actions/checkout` means full history, not shallow).

## Pipefail + early readers

**Bug:**

```bash
set -euo pipefail

# intent: "does any .go file declare `package main`?"
find . -maxdepth 1 -name '*.go' -exec grep -l '^package main' {} \; -print | grep -q .
```

When multiple files match, `find` keeps writing to the pipe while `grep -q .` exits on the first line. `find` gets SIGPIPE, so the pipeline returns 141 under `pipefail` and the step fails — even though there ARE matching files. Wrapping the pipeline in `if pipeline; then …` has the same effect (the `if` branch evaluates as false).

**Fix 1 — capture into a variable (no reader):**

```bash
matches=$(find . -maxdepth 1 -name '*.go' -exec grep -l '^package main' {} +)
[[ -n "$matches" ]]
```

**Fix 2 — tell `find` to stop after first match (best for existence tests):**

```bash
match=$(find . -maxdepth 1 -name '*.go' \
  -exec grep -q '^package main' {} \; -print -quit)
[[ -n "$match" ]]
```

`-print -quit` exits find after the first match prints; no pipe pressure, no SIGPIPE.

## stderr merge contamination

**Bug:**

```bash
BUILD_TS=$(git show -s --format=%cI HEAD 2>&1)  # merge stderr into value
```

If `git show` exits 0 but writes a warning to stderr (e.g. `warning: CRLF will be replaced by LF` on Windows-line-ending repos), `BUILD_TS` now contains the warning text. Downstream code appends it to `-ldflags "-X main.buildTime=${BUILD_TS}"`, producing either a build failure or — worse — a successfully-shipped binary with a corrupted version string.

**Fix:** don't merge stderr. GitHub Actions shows stderr in the log naturally. If you need stderr for a diagnostic, capture it to a separate variable:

```bash
if ! BUILD_TS=$(git show -s --format=%cI HEAD 2>/tmp/err); then
  echo "::error::git show failed: $(cat /tmp/err)"
  exit 1
fi
# BUILD_TS is stdout only, safe to use in ldflags.
```

## Expression context availability

**Bug:**

```yaml
jobs:
  build:
    uses: org/.github/.github/workflows/reusable.yml@main
    with:
      # This WAS the template's conditional bun setup:
      setup-bun: ${{ hashFiles('package.json') != '' }}
```

`hashFiles()` is only valid in step-level expressions (`steps.*.env`, `steps.*.if`, `steps.*.run`, `steps.*.with`). GitHub rejects the whole workflow file at validation time. **The workflow then runs on every trigger and fails instantly** — not just triggers that match `on:` — because a validation-failed workflow emits a run record regardless.

Even worse: on reusable-workflow callers with no steps of their own, `hashFiles()` in `with:` would semantically evaluate *before* the reusable workflow's own checkout anyway, so even if actionlint didn't catch it, the function would see an empty workspace.

**Fix:** either move the conditional into the reusable workflow's steps (post-checkout), OR accept the cost of the unconditional setup. For `setup-bun` specifically, `bun install` takes ~10s and the commands behind it can be gated with `if [ -f package.json ]` inside the script.

**Rule of thumb:** the caller's `with:` block is static-ish — `github.*` context is available, `steps.*` / `hashFiles()` are not. Use `actionlint` locally before pushing.

## Workflow-file validation failure

**Symptom:** `gh run list` shows a failing run with `name: .github/workflows/foo.yml` (the file path shown INSTEAD of the workflow's `name:` field), triggered on an event your `on:` block shouldn't match.

**Cause:** the workflow file failed validation. GitHub couldn't even resolve `name:`, so it shows the path. Validation-failed workflows emit a failure run on *every* trigger the repo receives, regardless of whether `on:` matches.

**Diagnose:**

```bash
gh run view <run-id> --repo <repo>
# "This run likely failed because of a workflow file issue." confirms validation failure
```

**Fix:** run `actionlint` against the file. Common culprits:

- `hashFiles()` or `steps.*` in top-level `with:` (see above).
- Invalid matrix variable reference (e.g. `matrix.goarm` in `with:` when the narrowed matrix no longer includes an `arm/v*` entry).
- Missing required input on a reusable workflow call.
- YAML-level: tab/space mixing, unquoted special characters in flow-style arrays.

## Permission propagation

Reusable workflows run under the **caller's** token. If the reusable job declares `permissions: { security-events: write }` but the caller grants only `contents: read`, GitHub rejects the job at startup and you get `startup_failure` across every invocation — fleet-wide, if the broken template is shared.

**The specific netresearch incident:** a `gitleaks.yml` caller granted `contents: read` only; the reusable `gitleaks.yml` needed `security-events: write` to upload SARIF. Every consumer's gitleaks workflow startup_failure'd for 24+ hours, meaning zero secret scanning happened on any main push, while `gh run list` showed the `startup_failure` status but nothing in CI jobs to diagnose.

**Rule:** when writing a reusable workflow, put a **CALLER REQUIREMENTS** block at the top of the file listing every permission the caller must grant. Keep it copy-pasteable:

```yaml
# CALLER REQUIREMENTS
# ===================
# The caller's job-level `permissions:` block MUST grant at least:
#
#   permissions:
#     contents: read
#     security-events: write  # required for SARIF upload at the end
#     packages: write         # required to push the image to ghcr.io
#
# Less than this fails at workflow startup with a `startup_failure`
# run and no job output — GitHub rejects the caller before any step
# executes.
```

When reviewing PRs that touch caller workflows, the first thing to check is that the caller's `permissions:` is ≥ what every reusable workflow it calls declares.

## Expression gotchas — release & multi-trigger workflows

Workflows that accept both a "normal" trigger (e.g. `push: tags`) and a manual override (`workflow_dispatch` with inputs) repeatedly trip over the same expression-context quirks. Each cost us a round of Copilot back-and-forth in the release-process doc; bundling them here so the next reader finds them in one place.

### `inputs.*` is not defined outside `workflow_dispatch` / `workflow_call`

```yaml
on:
  push:
    tags: ['v*']
  workflow_dispatch:
    inputs:
      tag: { required: true }

jobs:
  publish:
    steps:
      - uses: actions/checkout@...
        with:
          ref: ${{ inputs.tag || github.ref_name }}   # FAILS on push.tags
```

On `push.tags`, GitHub evaluates `inputs.tag` and raises *"Unrecognized named-value: 'inputs'"*. The workflow fails before any step runs.

**Fix:** use `github.event.inputs.*`, which resolves to an empty string on non-dispatch events:

```yaml
          ref: ${{ github.event.inputs.tag || github.ref_name }}
```

### On `workflow_dispatch`, `github.ref_name` is the dispatch source, not a tag

A workflow triggered via the Actions UI from `main` has `github.ref_name == 'main'`, even if the user supplied a tag via an input. Tag-source-of-truth workflows (release publishes, asset builds) must **explicitly** checkout the input tag, or they'll build assets from `main` HEAD and upload them to the tag's release:

```yaml
      - uses: actions/checkout@...
        with:
          ref: ${{ github.event.inputs.tag || github.ref_name }}
          fetch-tags: true
```

### GitHub Actions expressions have no ternary

`a ? b : c` is a YAML-level syntax error — GHA expressions only support `&&` / `||`. The idiom is:

```yaml
# "if cond then A else B" -->  cond && A || B
make_latest: ${{ github.event_name == 'workflow_dispatch' && 'false' || 'true' }}
```

Watch for the **truthy-string trap**: `'false'` is a non-empty string, so it's truthy. If you're branching on a boolean input, wrap it in `fromJSON()` to convert the string `'false'` to actual `false`:

```yaml
make_latest: ${{ fromJSON(github.event.inputs.make_latest || 'true') && 'true' || 'false' }}
```

Without `fromJSON`, `'false' && 'true' || 'false'` evaluates to `'true'` because the string `'false'` is truthy.

### Hyphenated input names force bracket-expression access

```yaml
inputs:
  make-latest: { type: boolean }   # hyphen

# Must be referenced as:
${{ inputs['make-latest'] }}       # not inputs.make-latest (parsed as subtraction!)
```

Prefer underscored names (`make_latest`) so dot-notation works. Matches GitHub's own action parameter style (`softprops/action-gh-release` uses `make_latest`, not `make-latest`).

## Related

- [actionlint-guide.md](./actionlint-guide.md) — how to catch these at author-time
- [reusable-workflow-security.md](./reusable-workflow-security.md) — trust model for external workflows
