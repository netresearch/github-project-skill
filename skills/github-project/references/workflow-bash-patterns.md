# Bash Patterns in GitHub Actions `run:` Steps

Recurring shell-scripting gotchas that turn workflow `run:` steps into silent data-loss bugs or, worse, build-passing-while-broken releases. Every entry here has caused a real incident in the netresearch fleet; fix each case up-front when you write new reusable workflows.

## Quick Index

| Symptom | Cause | See |
|---|---|---|
| Custom `::error::` never fires; step just exits non-zero with a one-line `exit` | `set -e` aborts on `VAR=$(failing-cmd)` BEFORE your diagnostic runs | [Generic shell pitfalls](#generic-shell-pitfalls) |
| Detection works for one match but "forgets" when several match | SIGPIPE race under `set -o pipefail` with early-exiting readers | [Generic shell pitfalls](#generic-shell-pitfalls) |
| Binary has mangled version/ldflag; release log "looks fine" | `2>&1` merged stderr into a captured variable | [Generic shell pitfalls](#generic-shell-pitfalls) |
| ldflags silently drop values; no error | Expression in top-level job `with:` evaluated BEFORE reusable checkout | [Expression context availability](#expression-context-availability) |
| Matrix cell keeps receiving an input the condition was meant to suppress; the fix looks applied and changes nothing | `''` is falsy, so `cond && '' \|\| value` always yields `value` | [The empty string is falsy](#the-empty-string-is-falsy-in-actions-expressions) |
| Workflow runs on triggers it shouldn't, all jobs fail instantly | File failed validation — GitHub creates a failing run regardless of `on:` match | [Workflow-file validation failure](#workflow-file-validation-failure) |
| Random startup_failure across the whole fleet after a template change | Caller job permissions < reusable job's declared permissions | [Permission propagation](#permission-propagation) |
| Dispatch payload reaches `rm -Rf`, `git clone` or a console command | `client_payload.*` interpolated into a script instead of passed as an env var | [Untrusted payload fields](#untrusted-payload-fields-in-a-run-step-or-a-remote-script) |
| Annotations stop appearing mid-job after a rejected input | An error message echoed an untrusted value containing `\n::stop-commands::` | [Untrusted payload fields](#untrusted-payload-fields-in-a-run-step-or-a-remote-script) |
| Expression fails to evaluate; the file "looks right" | `''` inside a single-quoted YAML scalar collapsed to one quote | [toJSON in a single-quoted scalar](#tojson-inside-a-single-quoted-yaml-scalar) |
| `gh` fails with `fatal: not a git repository`, in a job that never checks out | `gh` infers the repository from a git remote, and there is none | [gh in a checkout-less job](#gh-in-a-job-that-does-not-check-out) |
| A `run:` step passed every local case and still broke in CI | The stub answered regardless of the environment the step actually runs in | [Exercising a run: step locally](#exercising-a-run-step-locally) |

## Generic shell pitfalls

`set -e` with `$(…)`, SIGPIPE under `pipefail` with an early reader, and `2>&1` inside a capture are not specific to Actions `run:` steps. The cli-tools skill's [shell pitfalls reference](https://github.com/netresearch/coding_agent_cli_toolset/blob/main/skills/cli-tools/references/shell-pitfalls.md) covers them, measured and under test, together with the other shell constructs that report success or emptiness that is not real. Two details matter most in a workflow step:

- An `::error::` line placed after a failing `VAR=$(cmd)` is never reached under `set -e`, so the log shows only the bare exit code. Put the assignment in the condition: `if ! VAR=$(cmd); then echo "::error::…"; exit 1; fi`, and check for empty output separately.
- For "does any file match", `find … -exec grep -q PATTERN {} \; -print -quit` stops after the first hit without a pipe, so there is no reader for SIGPIPE to race.

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

## The empty string is falsy in Actions expressions

**Bug:**

```yaml
${{ matrix.prefer-lowest && '' || matrix.symfony }}   # ALWAYS yields matrix.symfony
```

GitHub-Actions expressions treat `''` as falsy, so the truthy branch is discarded and the `||` branch wins unconditionally. The cell keeps receiving the input the condition was meant to suppress, and the fix looks applied while doing nothing.

**Fix:** the non-empty value belongs in the truthy branch. To suppress an input, invert the condition and put `''` behind `||`:

```yaml
${{ !matrix.prefer-lowest && matrix.symfony || '' }}  # correct
```

Ternaries with a non-empty string in both branches (`cond && 'lowest' || 'highest'`) are unaffected.

**Sweep for the broken form:** `grep -rnE "&& '' \|\|" .github/workflows/`.

The reason this is worth a rule rather than a footnote is how it fails: the workflow stays valid, actionlint says nothing, and the matrix cell simply stays red — which invites a diagnosis somewhere else entirely. Confirm the fix actually ran (`gh run view <id> --json headSha`) before blaming a dependency.

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

## Untrusted payload fields in a `run:` step or a remote script

`repository_dispatch` `client_payload.*` is the same trust class as an issue title: whoever holds a write token on the repo composes it, and the sender usually forwards a value it took from somewhere else (a branch name, a `composer.json`). Three rules, all from t3docs-ci-deploy, where `rm -Rf ${{ … }}/${{ … }}` ran against the production documentation host.

**1. Validate the fields as what they are, in a step of their own, first in the job.** For a path segment: no character outside `[A-Za-z0-9._-]`, no `..`, no leading `.` or `-`. The leading dash is not cosmetic — `-q` reaching a Symfony console command as a positional argument is parsed as an option cluster.

```bash
for name in TYPE_SHORT VENDOR NAME; do
  value="${!name}"
  case "$value" in
    *[!A-Za-z0-9._-]* | *..* | .* | -* | '')
      echo "::error::client_payload field $name is not a plain path segment"
      exit 1
      ;;
  esac
done
```

**2. Never echo the value in the diagnostic.** A payload field may contain a newline, and the runner reads every line of step output: a value of `x\n::stop-commands::abc` disables annotations for the rest of the job, `\n::add-mask::/` masks unrelated log lines. The field name identifies the problem; the value adds nothing a rejected dispatch needs.

**3. Into a remote script, pass values as environment variables, never as text.** `appleboy/ssh-action`'s `envs:` input names variables from the step `env:`; drone-ssh uppercases each name and emits `export NAME='value'` with the value single-quote-escaped (`escapeArg`), so no payload character can leave its argument. Quote at the point of use, and require the variable — an empty segment silently collapses a path onto its root:

```yaml
# The validation step from rule 1 runs first in this job; without it the
# transport is safe but the value is still whatever the sender put in.
- uses: appleboy/ssh-action@<sha>
  env:
    TARGET_PATH: ${{ secrets.TARGET_PATH }}
    VENDOR: ${{ github.event.client_payload.vendor }}
  with:
    envs: TARGET_PATH,VENDOR
    script: |
      : "${TARGET_PATH:?not set}" "${VENDOR:?not set}"
      rm -Rf "$TARGET_PATH/$VENDOR"
```

An **action input** cannot take this route — `appleboy/scp-action`'s `target:` is interpolated by the action itself, so a destructive `rm: true` upload depends on the validation step having run first in the same job. Say so in a comment above it; step order is the only thing holding it.

## `toJSON()` inside a single-quoted YAML scalar

```yaml
# Broken - YAML turns '' into ' before the expression is ever evaluated
data: '{"id":${{ toJSON(github.event.client_payload.id || '') }}}'

# Correct - a folded scalar carries the expression verbatim
data: >-
  {"id":${{ toJSON(format('{0}', github.event.client_payload.id)) }}}
```

Expression strings are single-quoted, and inside a single-quoted YAML scalar `''` is the escape for one quote. The parser hands the runner `… || ')` and the workflow fails at expression evaluation, far from the line that caused it. A single-quoted scalar is not ruled out — it works when every quote of the expression is doubled (`format(''{0}'', x)`, an empty string as `''''`) — but the folded scalar removes that bookkeeping, and one missed doubling changes the expression silently. Check what the file actually parses to (`yq '.jobs.x.steps[0].env.data'`) rather than what it looks like.

Two related points on building JSON in a workflow: `toJSON` emits the value's native type, so an id that arrives as a number is no longer a JSON string for the receiver — wrap it (`toJSON(format('{0}', …))`) when the consumer expects one. And hand-quoting the field (`"id":"${{ … }}"`) is the injection: a quote in the value appends keys to your body, which a downstream `jq -c .` then resolves in the attacker's favour.

## `gh` in a job that does not check out

**Bug:** a job that only downloads an artifact — a release-publishing job, an evidence collector, anything that works on `dist/` rather than on the tree — calls `gh` and gets:

```
fatal: not a git repository (or any of the parent directories): .git
```

`gh` resolves the repository from a git remote in the working directory. `GH_TOKEN` is set, the API is reachable, the permissions are right, and it still cannot tell which repository you mean.

**Fix:** name it, from the context GitHub already provides.

```yaml
env:
  GH_TOKEN: ${{ github.token }}
  REPO: ${{ github.repository }}
run: |
  gh release view "$TAG" --repo "$REPO" --json assets
```

Cheap source check before shipping such a step — per invocation, not per line, because two `gh` calls can share a line and a `gh pr`/`gh run` is just as affected as a `gh release`:

```bash
# extract first, then read the shell — the second grep works on the step body,
# not on the YAML, and a `yq | grep` pipeline is the shape the data-tools hook
# stops (rightly, for field access) even when the grep is aimed at the output.
yq -r '.jobs.<job>.steps[-1].run' .github/workflows/x.yml > step.sh
grep -oE 'gh [a-z-]+ [a-z-]+[^|;&]*' step.sh \
  | grep -v -- '--repo' \
  || echo 'every gh invocation names its repository'
```

Anything printed is an invocation to fix. This shipped to a fleet-wide reusable workflow and failed on every release until it was caught.

## Exercising a `run:` step locally

A `run:` step is shell, so it can be run before it reaches CI — which is worth doing for anything that gates a release, because its failure path is the part CI will not exercise on a good day.

```bash
HARNESS=$(mktemp -d)

# the step itself, verbatim, without hand-copying it out of the YAML
yq -r '.jobs.<job>.steps[-1].run' .github/workflows/x.yml > "$HARNESS/step.sh"

# a stub for whatever CLI it drives, first on PATH
mkdir -p "$HARNESS/bin" && cat > "$HARNESS/bin/gh" <<'SHIM'
#!/usr/bin/env bash
...answer per $MODE...
SHIM
chmod +x "$HARNESS/bin/gh"

# one case per invocation, with a captured status. Absolute paths: the step
# runs from a sandbox directory, so a relative `step.sh` would not resolve.
mkdir -p "$HARNESS/sandbox"
( cd "$HARNESS/sandbox"
  PATH="$HARNESS/bin:$PATH" MODE=missing GITHUB_OUTPUT=out.txt \
    bash -eo pipefail "$HARNESS/step.sh"
  echo "rc=$?" )
```

`bash -eo pipefail` because the extracted body is only what was under `run:` — the runner supplies `bash -e {0}`, and `pipefail` comes from a `set -o pipefail` inside the body. A step that sets its own options makes the flags redundant, which is harmless; a step that relies on the runner's needs them, or the harness silently passes failures the job would have caught.

One case per subshell matters for the same reason it does anywhere: `set -e` behaves differently when a command's status is consumed by a pipe or a `||`, so a harness that wraps the variants in functions measures the harness.

**The stub must model the environment, not only the logic.** A stub that answers every call regardless of context proves the branches and nothing about where the step runs. Four such cases passed for a step that then failed in CI on `fatal: not a git repository` — the stub had never cared which directory it was called from. Teaching it to refuse a call that omits `--repo` when the working directory is not a checkout turned that defect into a failing case:

```bash
if ! printf '%s\n' "$@" | grep -qx -- '--repo'; then
  git rev-parse --git-dir >/dev/null 2>&1 || { echo "failed to run git: fatal: not a git repository" >&2; exit 1; }
fi
```

Ask of any such harness: *if the real thing broke the way it actually breaks, would this stub notice?*

## Related

- [actionlint-guide.md](./actionlint-guide.md) — how to catch these at author-time
- [reusable-workflow-security.md](./reusable-workflow-security.md) — trust model for external workflows
