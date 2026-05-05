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

To pick up upstream changes after merging the fix:

- Push a new commit to the PR (`git commit --allow-empty -m "trigger ci"` works), or
- Close + reopen the PR, or
- Trigger a fresh `workflow_dispatch` run.

`gh run rerun` is fine for genuinely transient failures (network blips, rate limits) — not for "I fixed the upstream reusable workflow."

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
