# Reusable Workflow Pitfalls

Operational and structural pitfalls when authoring reusable workflows and the composite actions they use. Distinct from `reusable-workflow-security.md` — that doc covers supply-chain trust and SHA pinning of *external* actions; this doc covers structural traps that have bitten in practice when building *internal* reusable workflows.

## 1. `./` does NOT resolve to the reusable workflow's repo

When a workflow is invoked via `workflow_call`, references like `uses: ./.github/actions/foo` are resolved against the **consumer's** workspace, not the reusable workflow's repo. The action will fail to load unless the consumer happens to have an identically-named local action.

GitHub documents this directly: "Local actions in workflows that are called as a reusable workflow are not supported." (See [Reusing workflows — limitations](https://docs.github.com/en/actions/sharing-automations/reusing-workflows#limitations).)

To call a composite action from a reusable workflow, reference it absolutely:

```yaml
# In the reusable workflow:
uses: org/repo/.github/actions/foo@<sha>   # works (absolute reference)
# uses: ./.github/actions/foo              # FAILS at the consumer
```

## 2. Composite-action references must be SHA-pinned

Internal `@main` references are accepted for **full reusable workflows** (`uses: org/repo/.github/workflows/foo.yml@main`) — see `reusable-workflow-security.md`. But **composite actions** (`uses: org/repo/.github/actions/foo@main`) are different: the consumer's runner resolves them under the consumer's allow-list policy. A consumer enforcing "all actions must be SHA-pinned" will reject the reusable workflow's job entirely, even though the reusable workflow file itself is unchanged.

This is enforced mechanically by checkpoint **GH-34**.

```yaml
# Inside a reusable workflow:
- uses: org/repo/.github/actions/preflight-gate@<40-char-sha>   # OK
# - uses: org/repo/.github/actions/preflight-gate@main          # breaks SHA-pinned consumers
```

When you self-reference a composite action inside the same repo that hosts the reusable workflow, you create a chicken-and-egg: the SHA you pin to must already exist in the same PR you're authoring. Two options: (a) inline the action's body as bash steps directly in the workflow (avoiding the cross-action `uses:`), or (b) land the composite action first, then SHA-pin to it in a follow-up PR.

## 3. `gh run rerun` caches `@ref` resolution

When a workflow run is created, GitHub records the resolved SHAs of every `uses: org/repo/...@ref` at that moment. **Re-running the same run replays those exact SHAs** — it does not re-evaluate the refs. This means: if you fix a bug in an upstream reusable workflow and merge the fix, then re-run a failed workflow that consumed `@main`, you will get the **old, broken** body.

To pick up upstream changes after merging the fix, you must create a **new** run — the ref is not re-resolved per-job or on rerun:

- **PR:** push a new commit (`git commit --allow-empty -m "trigger ci"`), or close + reopen the PR (`gh pr close N && gh pr reopen N`), or trigger a fresh `workflow_dispatch` run.
- **Scheduled / non-PR repo with no `workflow_dispatch`:** create a throwaway branch at the default-branch SHA to fire a fresh `push` run, then delete it:

  ```bash
  gh api -X POST repos/O/R/git/refs -f ref=refs/heads/ci/verify -f sha=<sha>
  gh api -X DELETE repos/O/R/git/refs/heads/ci/verify
  ```
- A scheduled-only repo whose default branch has no new commit keeps *displaying* the stale red run until its next push/schedule — the fix is in, the badge just hasn't refreshed.

`gh run rerun` is fine for genuinely transient failures (network blips, rate limits) — not for "I fixed the upstream reusable workflow." (Distinct from the consumer's own base-SHA staleness; see `gh-cli-reference.md` → "`gh run rerun` re-runs the OLD state".)

> **Re-triggering a tag workflow** after fixing the workflow file requires **moving the tag** (delete the remote tag, re-tag the fixed default-branch tip, push) — tag events fire against the workflow file *at the tag's commit*. DANGER: only safe when the package is on **no** registry — Packagist/npm webhooks publish within seconds and stable versions are immutable. "The release workflow failed" does not mean nothing was published; check the registry first and prefer fix-forward with a patch version.

## 4. Permissions ceiling — caller cannot grant what it lacks

A reusable workflow's `permissions:` block sets the **maximum** scopes the called job is allowed to use. The actual token issued is the **intersection** of the caller's job-level `permissions:` and the reusable workflow's declared `permissions:`. If the calling job sets `permissions: {}` (empty), the reusable job receives a token with **zero** scopes regardless of what the reusable workflow declares.

When a reusable workflow gains a new requirement (e.g., a step that calls `gh api` and needs `actions: read`), every consumer's calling job must also be updated to grant that scope. Otherwise the new step fails with a 403 in production but works in your test repo where you happen to have broader permissions.

```yaml
# Consumer side — must include EVERY scope the reusable workflow needs:
jobs:
    call-shared:
        permissions:
            contents: read
            actions: read           # required by the reusable workflow's gh api step
            pull-requests: write
        uses: org/ci-workflows/.github/workflows/shared.yml@<sha>
```

See [GitHub docs — access and permissions](https://docs.github.com/en/actions/sharing-automations/reusing-workflows#access-and-permissions) for the full intersection rules.

> **See also:** [`reusable-workflow-security.md`](./reusable-workflow-security.md) for SHA-pinning and supply-chain trust of *external* actions.

## 5. Inline `config_data` overrides the repo's own config file

Linter actions that accept an inline `config_data:` (e.g. yamllint via a
reusable workflow) **replace** the consumer repo's own config file entirely —
they do not merge. A repo with a carefully tuned `.yamllint.yml` (ignore paths,
relaxed rules) silently has all of it discarded the moment the reusable workflow
passes its own inline defaults.

Provide inline defaults only as a *fallback*, when the repo has no config of its own:

```yaml
- name: Provide default config if the repo has none
  run: |
    if [[ ! -f .yamllint.yml ]]; then
      cat > .yamllint.yml <<'EOF'
    extends: default
    rules: { line-length: disable }
    EOF
    fi
- name: Lint
  uses: some/yamllint-action@<sha>   # picks up the repo's config, or the fallback
```

## 6. Fix the gap in the shared workflow, not per-project

When CI or quality logic lives in a shared reusable workflow (e.g. `netresearch/typo3-ci-*`), a gap or bug that surfaces in one consumer is almost always a gap in the **shared** workflow. Fix it upstream so every consumer inherits the fix — do not patch the single project's `.github/workflows/`.

Per-project patches defeat the point of the reusable workflow: they reintroduce the duplication the shared workflow exists to remove, drift out of sync as the shared workflow evolves, and force the same fix to be rediscovered in the next repo.

Before adding a guard, check, or fix to a project's own workflow files, ask whether the shared reusable-workflow repo already owns that concern — or should. If it does, land the change there and let the consumer pick it up via its `@main` / `@vX.Y.Z` reference (per [`reusable-workflow-security.md`](./reusable-workflow-security.md), internal reusable workflows are referenced by tag/branch, not SHA). Keep logic in a consumer only when it is genuinely project-specific.

This is distinct from pitfalls #1–#5 above (which cover *how* to author and reference reusable workflows) — this is about *where* a fix belongs.

### The consumer-side tell

The rule is easiest to apply as a property of the consumer's workflow file: **every job in a
consumer repo is a `uses:` of a shared workflow.** A job with its own `steps:` — checkout,
setup, install, run — is the smell, and third-party actions (`actions/checkout`,
`shivammathur/setup-php`, …) appearing anywhere outside the shared-workflow repo is the same
smell stated in terms of `uses:`. Verify with:

```bash
grep -rn "uses:" .github/workflows/ | grep -vi "YOUR_ORG/"
```

Anything that returns is either a genuinely project-specific exception or work that belongs
upstream. Pinning such an action to a SHA does not make it compliant — the pin is a separate
requirement (`reusable-workflow-security.md`), not a substitute for this one.

### Extending the shared workflow instead

When the shared workflow has no input for what the consumer needs, add one — this is the
supported path, not a workaround:

- Add the input **defaulting to off** (`type: boolean`, `default: false`) and gate the new
  job on it, so every existing consumer is unaffected. Verify the diff is purely additive
  (`git diff origin/main... -U0 | grep -E '^-[^-]'` returns nothing) — an existing consumer must not change
  behaviour because another repo needed a feature.
- Copy the action pins verbatim from a neighbouring job in the same file rather than picking
  versions independently; a shared workflow with two different `actions/checkout` SHAs is its
  own maintenance problem.
- Give the new job a graceful skip (a `::notice::`) when the consumer lacks the underlying
  script, so enabling the input in a repo that is not ready cannot hard-fail.
- Land it, then flip the input on in the consumer. The consumer's change is one line.

Do not reach for `unit-test-command`-style override inputs to smuggle an extra suite into an
existing job: those replace the job's instrumented default command and silently drop whatever
it did (coverage upload, for instance).

## 7. Run with zero jobs whose name is the file path = workflow-validation failure

A run with `conclusion: startup_failure` (or `failure`), **zero jobs**, and a displayed name that falls back to the workflow **file path** failed at workflow *validation*, before any job started. The exact reason is **only in the Actions UI banner** — it is not exposed via the REST API (`gh run view --log[-failed]` returns "log not found"; run/annotations/check-suite endpoints are empty). If you can't see the UI, ask for the banner text. Two causes seen in practice:

1. **Dead reusable-workflow reference** — a `uses:` pointing at a reusable workflow file that no longer exists (e.g. a deleted shared workflow); callers fail silently, sometimes for months. Inspect the `uses:` lines and `gh api`/`curl` the referenced files for 404.
2. **Permission mismatch** — the caller's job omits an explicit `permissions:` block, the repo's `default_workflow_permissions` is `read`, but a nested reusable job requests e.g. `security-events: write`. UI error: "The nested job 'X' is requesting 'security-events: write', but is only allowed 'security-events: none'." Deceptive because a **byte-identical** workflow file passes in sibling repos whose repo-default permissions are permissive — it is repo-environmental, not a file diff. Fix at the caller per pitfall #4: grant the calling job exactly the scopes the reusable declares.

```bash
gh api repos/O/R/actions/permissions --jq '.default_workflow_permissions? // ""'   # reveals a restrictive 'read' default
```


## 8. `release: published` never fires for a release a workflow created

A workflow that reacts to releases with

```yaml
on:
  release:
    types: [published]
```

is **inert for every automated release**. GitHub does not raise events from
actions taken with the default `GITHUB_TOKEN` — a deliberate guard against
recursive runs — and the release is created by the release workflow using
exactly that token. The trigger only fires for releases a human creates in the
UI or via a PAT.

This fails silently in the worst way: the workflow is registered, `state:
active`, and simply never runs. Nothing appears in the Actions tab to explain
the absence.

Trigger off the producing workflow instead:

```yaml
on:
  workflow_run:
    workflows: ["Release"]
    types: [completed]

jobs:
  verify:
    # A run that failed has nothing to verify, and head_branch is only a tag
    # when the run came from a tag push.
    if: >-
      github.event.workflow_run.conclusion == 'success' &&
      startsWith(github.event.workflow_run.head_branch, 'v')
```

`workflow_run` observes a workflow *run*, not a repository event, so the
GITHUB_TOKEN suppression does not apply to it.

Two constraints come with it:

- The workflow file must be on the **default branch**. A `workflow_run`
  trigger added on a feature branch does nothing until it is merged — so it
  cannot be exercised on the PR that introduces it.
- **`workflow_run` does not chain.** A workflow started by `workflow_run`
  cannot itself trigger another one.

**A repo's history can mislead you here.** Checking for past `event=release`
runs is not evidence the trigger works today: a repo that once created releases
by hand will show dozens of them, all predating the automation.

### Corollary: test the trigger you ship, not a convenient one

Adding `workflow_dispatch` alongside the real trigger makes the workflow easy to
exercise — and a dispatch run proves only that the *jobs* work. It says nothing
about whether the event you actually depend on ever arrives. A gate can pass its
manual test and still be dead in production. If the real trigger cannot be
exercised before merge, say so rather than treating the dispatch run as proof.

## 9. Converting an inline job to a reusable call renames its check → update the required contexts

When you replace an inline job with a `uses:` reusable-workflow call, the surfaced
check name changes from `<job-id>` to **`<caller-job-id> / <reusable-job-name>`**.
Example: an inline `build:` job reported as `build`; after routing it through
`build-container-bake.yml` it reports as `build / Build Container (Bake)`.

Any branch-protection **required status check** or **merge-queue ruleset** that
still lists the *old* context (`build`) now waits on a check that will never
report — the PR sits `BLOCKED` / the merge-group is ejected, forever, even though
every visible check is green.

**Fix:** the required-context list must be migrated alongside the workflow change.
Because the exact new name isn't always predictable, observe it on the first run,
then update the gate:

```bash
# 1. New context name from the PR's first run
gh pr checks <PR> --repo OWNER/REPO | grep -i build

# 2a. Classic protection — preserve the other contexts, swap the renamed one
gh api repos/OWNER/REPO/branches/main/protection/required_status_checks \
  --jq '.contexts'                       # read current
# PATCH back with the old name replaced by "build / Build Container (Bake)"

# 2b. Merge-queue / ruleset — edit the ruleset's required_status_checks rule
gh api repos/OWNER/REPO/rulesets/<id>    # find the required_status_checks rule
# PUT the ruleset back with the context renamed
```

Do this in lockstep with merging the workflow PR, or the repo is unmergeable
until someone notices. (See also `dependency-management.md` for enabling a
required check via a ruleset when classic `required_status_checks` isn't set.)

## Own reusables stay `@main` — never SHA-pin them

Reusables in Netresearch-owned repos (`netresearch/.github`, typo3-ci-workflows) are called `@main` (or a tag once releases exist), NEVER by commit SHA: pinning freezes every consumer to a snapshot and defeats "fix once, all pick it up". The trust model differs from third-party actions (which DO get SHA-pinned). SonarCloud `githubactions:S7637` flags every new `@main` reusable line on migration PRs — a false positive for first-party reusables: mark Safe/Won't-fix (or add an org-level exception for `netresearch/.github/**@main`), never capitulate with a SHA pin.

## Validating a new reusable: the first caller IS the test — use a temp branch pin

A new reusable is inert until a caller runs it. Loop: wire the first caller `@main`, let its PR CI fail, fix the reusable on a branch, and validate BEFORE merging by temporarily pointing the caller at the fix branch (`uses: …/x.yml@fix/branch` — GitHub allows branch refs). Once green: merge the reusable fix, revert the caller to `@main` (the fix branch dies on merge), confirm green, and squash the temp-pin/revert commits out of the caller PR.

## Inline → reusable migration checklist (each bit a real PR)

1. **The calling job must grant `permissions:`** (usually `contents: read`) — with workflow-level `permissions: {}` and no job grant the run **startup-fails** and the reusable's checks NEVER APPEAR; a repo without required checks then looks deceptively green. Verify the reusable RAN: `gh run list --branch <b> --json name,conclusion` shows `success`, not `startup_failure`.
2. **Required-check contexts go stale**: inline names (`PHP 8.2`) become `<caller-job-id> / <name>` (`php-ci / PHP 8.2`) — old contexts wait "Expected" forever. PATCH the protection contexts in the same change.
3. **`composer validate --strict`** (the reusable default) rejects intentional `*` constraints for virtual packages — pass `composer-validate: false` plus a non-strict `pre-install-cmd: "composer validate"`.
