<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# CI Runner Capacity — Diagnose Before You Optimize

A PR-to-release delay can contain review wait, workflow concurrency wait,
dependency wait, runner acquisition, execution, artifact transfer and publication.
Measure the complete path before changing parallelism. A below-cap peak alone
cannot distinguish an idle dependency graph from delayed runner acquisition.

## Establish the scope and quality contract

Inventory workflow **files**, triggered **runs**, expanded **jobs**, assigned
runner records and actual executions separately. One file can expand into many
matrix cells; several trigger events can repeat the same work. Count the PR,
merge-group and main graphs independently, including reusable workflows,
`needs`, conditions, environments, concurrency groups and publication triggers.
Preserve the required checks, supported matrix, suites, thresholds and qualified
review policy while optimizing.

GitHub-hosted standard concurrency is shared by the owning account, across
repositories. Check the [current limits](https://docs.github.com/en/actions/reference/limits)
and the account's actual support-adjusted allocation and runner types. A plan's
published default is a reference, not proof of the effective cap. Larger,
macOS, GPU and self-hosted pools can have different constraints. Do not infer
pool membership from a runner ID alone.

## Collect a reproducible cohort

The read-only collector retains successful API response bodies with their endpoint
and read times, explicit API hostname and authenticated principal, paginates repositories,
runs and jobs, and reads every run attempt. It re-reads each run after its jobs
and compares the final run and organization-repository inventories; a revision
or repository identity change makes the report incomplete.
It never cancels, reruns, changes rules or enqueues anything.
Failed reads retain the endpoint, read times and redacted error class. Subprocess
arguments, stderr and credentials are not copied into the report.

```bash
uv run skills/github-project/scripts/collect-runner-capacity.py \
  --org OWNER --since 2026-10-28T00:00:00Z --until 2026-10-29T00:00:00Z \
  > capacity.json
# Or --repo OWNER/REPO (repeatable); optional --head OWNER/REPO=40_HEX_SHA
jq '{complete, scope, errors, reads: (.reads | length)}' capacity.json
```

The scope is runs **created** in the specified window, among repositories
visible to the token. A prior-day run still executing can be absent: widen the
window and check older active runs before claiming an organization-wide live
backlog. Reads are non-atomic. Repository visibility and any failed page are
coverage limits, never evidence that unseen work is absent. A run search at
GitHub's 1,000-result ceiling returns incomplete: split the time window and
collect again. `complete: true` means the declared cohort was collected without
a detected error; it does not certify token visibility or an atomic snapshot.

`--head` matches repository names without regard to case and labels other heads
as obsolete **without dropping their cost**. Repeated repository names that
differ only in case are collected once; the first spelling and supplied head
selectors remain in the scope record.
Without an explicit expected head, currency is unspecified. Keep older pushes,
cancellations, duplicate events and reruns in the cost inventory; select the
current qualifying head separately for the release decision. Run attempts can
carry successful jobs with new administrative IDs and old execution times, so
do not sum attempt records as fresh executions. Use step times, runner identity
and logs to distinguish a real rerun from a carried result.

Sources: [workflow runs](https://docs.github.com/en/rest/actions/workflow-runs),
[workflow jobs](https://docs.github.com/en/rest/actions/workflow-jobs).

## Attribute time before choosing the lever

- **Assigned jobs:** a nonzero runner ID shows assignment. Unassigned queued
  records can still be waiting on `needs`, an environment approval or a
  concurrency group. A run-level `queued` status can coexist with running jobs;
  inspect jobs rather than treating every queued run as executor backlog.
- **Waiting:** `started_at - created_at` is an observed interval, not a measured
  executor queue. Establish when dependencies, conditions and approvals cleared
  from the workflow graph and event/log evidence. If that moment is unavailable,
  label readiness and executor wait unknown. Summed job waits overlap and do not
  equal the PR's elapsed wait.
- **Compute:** sum verified execution intervals for runner cost, grouped by
  runtime/pool. Compute peak occupancy by sweeping start/end events over the
  same observation window; separate historical carried records and incomplete
  intervals. An observed peak is a lower bound under incomplete coverage.
- **Critical path:** reconstruct dependencies and timestamps from PR creation
  through qualified reviews, checks, merge queue, main checks, release evidence
  and publication. Attribute each elapsed segment once. Contrast the critical
  path with summed runner time; faster off-path work can reduce cost without
  advancing publication.

Only diagnose a capacity cap when **ready** jobs compete with concurrent work
in the same constrained pool. A below-cap peak may instead mean dependencies,
conditions, serialized concurrency groups, different pools or missing data; it
does not establish acquisition-bound behavior or prove that job count is
irrelevant. Observe comparable windows across other repositories before blaming
GitHub's shared scheduler.

## Choose and verify the change

Reduce duplicate/obsolete PR work and repeated setup first. Coalescing jobs can
reduce acquisitions, but retain independent results, dependency/runtime
contracts, deadlines and failure diagnostics. Never trim a supported matrix or
move required tests to a schedule just to improve latency. More parallel jobs
can help an available pool and delay other repositories under contention.

Use PR cancellation for superseded PR revisions; preserve admitted merge-group,
main and release work. Tune merge-queue build concurrency against the entire
organization's ready width, not the target repo alone. Change required-context
names with their effective rules and validate every trigger path. Capacity
purchases or self-hosted runners require their own cost/security decision and
measured benefit; a higher cap does not guarantee faster acquisition.

Compare before/after cohorts with the same quality contract and similar queue
pressure. Report critical-path elapsed time, actual executions, runner-minutes,
obsolete work, coverage gaps and uncertainty. One faster run is an observation,
not a causal throughput result.

## Persist tool caches written inside `docker compose run --rm`

A linter/analyzer run inside `docker compose run --rm` writes to the container's
ephemeral filesystem — anything under the container's `/tmp` is discarded every
run and is uncacheable. Point the tool's cache at a **host-mounted** repo path
(PHPStan `tmpDir: var/cache/phpstan`, Rector `->withCache('var/cache/rector')`),
then `actions/cache` it:

- **Key** on `${{ github.run_id }}` (unique → never hits → always saves a fresh
  cache post-job) with `restore-keys` set to the key's prefix (restores the most
  recent prior cache) — save-fresh + restore-latest = incremental warmth.
- **Safe stale restore:** the tools self-invalidate (PHPStan salts on
  config+composer+PHP; Rector on the config-file hash), so a restored-but-stale
  cache only recomputes changed files, never a wrong result — so *don't* bake a
  content hash into the key; it just fragments the cache lineage.
- **uid:** the container writes as root (umask 022 → 0644 files), so the post-job
  save (runner user) reads them without a chmod.

Measured: a PHPStan-heavy Lint job dropped ~145s cold → ~72s warm.

## Verify every trigger path after a conditional change

When a workflow behaves differently by `github.event_name` / a flag / a matrix
cell, a green run of ONE path is not "done" — each path is separate code. Gating
coverage steps on `schedule` leaves the `pull_request` run green while the
coverage-on (`schedule`) path still hides a bug (e.g. a job that now exceeds its
`timeout-minutes`). Exercise the non-PR path on demand with `workflow_dispatch`
— but the trigger must already exist on the **default branch** to be
dispatchable. If it's *new in the PR*, that path is only verifiable after merge;
if it already exists on the default branch, you can dispatch the PR branch's
version directly. Either way, check it; don't assume.

## Scheduled runs cancelled by a push in the same concurrency group

A workflow with `concurrency: group: ${{ github.workflow }}-${{ github.ref }}`
puts `schedule`, `workflow_dispatch` and `push` runs on the default branch into
one group. With the default `queue: single`, GitHub keeps at most one
**pending** run per group: a newer run replaces the pending one even with
`cancel-in-progress: false`. That setting only protects the run that is already
**running**. (`queue: max` allows up to 100 pending runs, but GitHub rejects it
in combination with `cancel-in-progress: true` — see the fix below.)

A nightly run that waits behind a running push run is therefore cancelled by
the next push, before it starts a job. Observed in netresearch/t3x-nr-llm:
scheduled run 39209624988 (2026-10-19) was created at 06:23:25, waited behind
a push run that was still running, and was cancelled at 06:33:06 — one second
after push run 39210564782 was created.

Signature: conclusion `cancelled`, zero jobs, and a run of another event
created in the same group within a second of the cancellation. The second
command below lists candidates only: it shows creation times, not the group, so
confirm that the candidate's event and ref fall into the same group and that its
`created_at` matches the cancelled run's `updated_at`.

```bash
R=OWNER/REPO; RUN=RUN_ID
# 0 = the run never started a job
gh api "repos/$R/actions/runs/$RUN/jobs?per_page=100" --paginate --jq '.jobs|length'
# The cancellation time of the run under suspicion
gh api "repos/$R/actions/runs/$RUN" --jq '"\(.event) \(.head_branch) \(.updated_at)"'
# Candidates for the replacing run (same workflow and branch, created around then)
gh api "repos/$R/actions/workflows/ci.yml/runs?branch=main&created=FROM..TO" \
  --jq '.workflow_runs[] | "\(.id) \(.event) \(.created_at) \(.conclusion)"'
```

Fix: give schedule and manual runs their own group and leave the other groups
as they are:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}${{ (github.event_name == 'schedule' || github.event_name == 'workflow_dispatch') && format('-{0}', github.event_name) || '' }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

Push and pull-request runs keep the group they had; only pull-request runs
cancel their predecessor. `queue: max` is no alternative here: the
`cancel-in-progress` expression is true for pull requests, and GitHub refuses
`queue: max` together with `cancel-in-progress: true`. Where a workflow never
cancels in progress, `queue: max` in the shared group keeps the scheduled run
waiting instead. Applied in netresearch/t3x-nr-llm#1155
(<https://github.com/netresearch/t3x-nr-llm/pull/1155>).
