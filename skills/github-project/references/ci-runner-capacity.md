<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# CI Runner Capacity — Diagnose Before You Optimize

A slow GitHub Actions pipeline is often **runner-acquisition-bound**, not
job-duration-bound. Before speeding up jobs or trimming the matrix, measure
which one you actually have — the fixes are different, and the common one
(trim job count) buys nothing under the common cause.

## The concurrency cap

GitHub-hosted runners are capped **org-wide**, by plan, regardless of repository
visibility (public repos get no relief):

| Plan | Concurrent jobs (standard runners) |
|---|---|
| Free | 20 |
| Pro | 40 |
| Team | 60 |
| Enterprise | 500 |

Source: <https://docs.github.com/en/actions/reference/limits>. One PR push can
easily trigger 40–50 jobs across CI + checks + e2e, so a single PR on the Free
plan needs multiple full waves of the org's *entire* runner allotment — shared
with every other repo.

## The two regimes, and why the distinction decides the fix

- **Cap-bound** (peak concurrency ≈ the cap): jobs wait on *each other*.
  Trimming job count and fanning out less both help.
- **Acquisition-bound** (peak concurrency **below** the cap, yet jobs still
  queue): each job waits individually for GitHub to hand it a machine on the
  shared pool. Job count is irrelevant — N jobs and N/2 jobs finish at the same
  time because they wait in parallel. **Fan-out is correct here**; trimming the
  matrix buys ≈0 wall clock.

The trap: concluding "our jobs are slow, cut the matrix" when peak concurrency
was never near the cap. Measure first.

## Measure it (one run)

```bash
R=OWNER/REPO; RUN=RUN_ID
# Per-job queue (started-created) vs run (completed-started), in minutes:
gh api "repos/$R/actions/runs/$RUN/jobs?per_page=100" --jq '
  .jobs[] | select(.conclusion!=null) |
  { q: (((.started_at|fromdateiso8601)-(.created_at|fromdateiso8601))/60),
    r: (((.completed_at|fromdateiso8601)-(.started_at|fromdateiso8601))/60),
    n: .name } | "queue=\(.q|floor)m run=\(.r|floor)m \(.n)"'
```

**Count jobs, never runs.** A workflow *run* reports `status: queued` while its own jobs are already executing, so `actions/runs?status=in_progress` systematically under-reports throughput and `status=queued` over-reports the backlog. Measured 2026-09-18: a run-level sweep across 21 repositories returned "0 in progress, 37 queued" and read as a total stall; the job-level count over the same runs was **624 completed, 15 in progress, 237 queued** — the pipeline was working the whole time. Diagnosing a stall off the run-level filter sends you looking for an outage that is not there.

```bash
# Backlog at the level that actually moves
for R in $REPOS; do
  gh api "repos/$R/actions/runs?per_page=15" --jq '.workflow_runs[] | select(.status=="queued" or .status=="in_progress") | .id' |
  while read -r id; do
    gh api "repos/$R/actions/runs/$id/jobs?per_page=100" --paginate --jq '.jobs[].status'
  done
done | sort | uniq -c
```

Then compute two totals and the peak:

- **Σ queue job-min vs Σ run job-min.** If queue ≫ run (e.g. 415 vs 50), the
  pipeline is waiting for machines, not computing.
- **Peak concurrent jobs** — sweep-line the `started_at`/`completed_at` events.
  Below the plan cap ⇒ acquisition-bound.

Control for noise: queue time swings run-to-run with whatever else the org is
running. Compare runs at *similar* queue pressure, not two arbitrary runs — a
single congested run makes any change look worthless.

## What each regime's real fix is

- **Acquisition-bound** — the lever is **capacity**, a business decision, not a
  workflow edit: upgrade the plan (Free 20 → Team 60), or add self-hosted
  runners. (Self-hosted on a **public** repo runs untrusted PR code — a known
  hazard; gate on `pull_request` from forks.) Note: a higher *cap* does not
  necessarily lower *acquisition latency* on the shared pool — verify before
  spending.
- **Cap-bound** — trim job count (a matrix that removes a required-by-name
  status check makes PRs un-mergeable, so change the ruleset first), gate
  docs-only PRs, and add `concurrency: cancel-in-progress` for `pull_request`
  (never for `merge_group`/push-to-main).

## Compute is still worth cutting

Even when it buys no wall clock, halving job-minutes lowers org-wide queue
pressure for *every* repo sharing the pool — so making jobs faster is the right
first move; just don't promise a wall-clock win it can't deliver under the
acquisition-bound regime.

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
