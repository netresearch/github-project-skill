# Auto-merge & Auto-approve Guide

Auto-merge for dependency bots and auto-approve for solo maintainers.

## Solo Maintainer: Auto-approve via `pr-quality.yml`

Solo maintainer projects should keep `required_approving_review_count >= 1` (required for OpenSSF Scorecard and good practice) and use a `pr-quality.yml` workflow that auto-approves PRs from repo collaborators.

**How it works:** The workflow checks the PR author's repository permission. If they have `write` or `admin` access, it approves the PR automatically via `github-actions[bot]`, satisfying the review requirement without manual intervention.

**Use the template:** `assets/pr-quality.yml.template` → `.github/workflows/pr-quality.yml`

**Branch protection settings:**

```bash
gh api repos/OWNER/REPO/branches/main/protection/required_pull_request_reviews -X PATCH \
  --input - << 'EOF'
{
  "required_approving_review_count": 1,
  "dismiss_stale_reviews_on_push": true,
  "require_code_owner_reviews": false
}
EOF
```

**Who gets auto-approved:**

| PR author | Approved by | Auto-merged by |
|-----------|-------------|----------------|
| Repo collaborator (write/admin) | `pr-quality.yml` | Manual merge or auto-merge rule |
| Dependabot / Renovate / release-please | `auto-merge-deps.yml` | `auto-merge-deps.yml` (via `--auto`) |
| External contributor | Manual review required | Manual merge |

> **Bootstrap note:** When first adding `pr-quality.yml`, the PR that introduces it must be approved manually (the workflow isn't on the base branch yet). All subsequent PRs auto-approve.

## Troubleshooting Quick Reference

| Symptom | Cause | Fix |
|---------|-------|-----|
| PR BLOCKED, checks pass | Check names don't match | Update branch protection to use exact names (e.g., `job (variant)` not `job`) |
| PR BLOCKED, `reviewDecision: REVIEW_REQUIRED` | `require_code_owner_reviews: true` | Disable code owner reviews or add code owner approval |
| PR BLOCKED, unresolved threads | `required_conversation_resolution: true` | Resolve all review threads before merging |
| PR has pending reviewers | Requested reviewers haven't responded | Wait for all requested reviewers to submit their review |
| Renovate PR not using bypass | Workflow racing with Renovate | Only approve in workflow; let Renovate enable auto-merge via `platformAutomerge` |
| CI can't push to main | Branch protection blocks direct push | Use Renovate `lockFileMaintenance` instead |
| Workflow not triggering | Rapid merges skip push events | Add `workflow_dispatch` trigger, run manually |
| "Merge method X not allowed" | Wrong merge strategy | Use auto-detection (see below) or check `gh api repos/O/R --jq '{merge: .allow_merge_commit, squash: .allow_squash_merge, rebase: .allow_rebase_merge}'` |
| "Rebase merges cannot be automatically signed" | Signed commits + rebase | Enable squash merge on the repo; rebase merges cannot be auto-signed by GitHub |
| Bot detection misses reruns | `github.actor` changes on synchronize | Use `github.event.pull_request.user.login` instead of `github.actor` |
| Third-party gitleaks scan fails on bot PRs | Legacy `gitleaks-action@v2` needs a license secret Dependabot cannot read | Call `netresearch/.github/.github/workflows/gitleaks.yml@main` (betterleaks, no license); tune `.gitleaks.toml` for false positives |
| Old PRs not auto-merging | Opened before workflow existed | Comment `@dependabot rebase` / `@renovate rebase` to trigger `synchronize` |
| Can't merge workflow file PRs | `GITHUB_TOKEN` lacks `workflows` scope | Merge manually; use workflow check in `auto-merge-direct.yml` template |
| Auto-approve skipped, PR stuck `REVIEW_REQUIRED` or blank `reviewDecision` | Auto-approve raced with Copilot reviewer | Re-run the auto-approve workflow after Copilot finishes; long-term fix is adding `pull_request_review` trigger — see [Auto-Approve Race Condition with Copilot Reviewer](#auto-approve-race-condition-with-copilot-reviewer) |

## Auto-Approve Race Condition with Copilot Reviewer

**This section is the canonical home for the "PR stuck BLOCKED despite green CI + explicit approval" gotcha.** Project-level `CLAUDE.md` entries should cross-reference this file rather than restating the details.

When using a solo-maintainer auto-approve workflow alongside GitHub Copilot as a reviewer, a race condition can leave PRs stuck blocked even though every gate appears satisfied:

1. New push triggers both the auto-approve workflow and Copilot review
2. Auto-approve runs first, sees Copilot as a pending reviewer, skips approval silently
3. Stale review dismissal (`dismiss_stale_reviews_on_push: true`) clears any previous approvals from the push
4. Copilot finishes reviewing with state `COMMENTED` (not `APPROVED`) — Copilot almost never actively approves
5. No approval exists anywhere; PR stays `BLOCKED`

**Symptoms** — `gh pr view N --json mergeStateStatus,reviewDecision` returns one of:

- `{"mergeStateStatus":"BLOCKED", "reviewDecision":"REVIEW_REQUIRED"}` (classic case)
- `{"mergeStateStatus":"BLOCKED", "reviewDecision":""}` (no review decision computed yet — seen when Copilot is mid-review and the repo has `required_approving_review_count >= 1`)

In both cases: all CI status checks are `SUCCESS`, there are no `CHANGES_REQUESTED` reviews, no unresolved review threads, and the auto-approve job reports `success` in `gh run list`. The approval simply never happened.

### Diagnosis

Confirm the silent-skip is the cause before re-running anything:

```bash
# 1. Find the latest auto-approve run for THIS PR's head commit and its job id.
#    Scoping by head_sha prevents picking up runs from other PRs/branches.
HEAD_SHA=$(gh pr view PR_NUMBER --repo OWNER/REPO --json headRefOid --jq .headRefOid)
RUN_ID=$(gh api "repos/OWNER/REPO/actions/runs?head_sha=$HEAD_SHA&per_page=20" \
  --jq '[.workflow_runs[] | select(.name == "PR Quality Gates")] | .[0].id')
JOB_ID=$(gh api "repos/OWNER/REPO/actions/runs/$RUN_ID/jobs" \
  --jq '.jobs[] | select(.name | test("Auto-[Aa]pprove")) | .id' | head -1)

# 2. Inspect the job log for the skip marker. Use `gh run view --log` — the
#    raw /logs API returns a zip archive that won't grep cleanly.
gh run view --log --job="$JOB_ID" --repo OWNER/REPO \
  | grep -iE "skip|copilot|pending reviewer|requested_reviewers"
```

If the log contains a line like "Skipping approval: pending reviewers" or shows `requested_reviewers` containing `copilot-pull-request-reviewer[bot]`, the race condition is confirmed.

Also useful — current reviewer state:

```bash
gh api repos/OWNER/REPO/pulls/PR_NUMBER \
  --jq '{requested_reviewers: [.requested_reviewers[]?.login], requested_teams: [.requested_teams[]?.slug]}'
```

An empty `requested_reviewers` after Copilot's review has landed confirms Copilot is no longer blocking — so a rerun will now succeed.

### Fix — re-run the workflow

```bash
# Scope the lookup to THIS PR's head commit — filtering only by workflow name
# can return runs from other PRs/branches.
HEAD_SHA=$(gh pr view PR_NUMBER --repo OWNER/REPO --json headRefOid --jq .headRefOid)
RUN_ID=$(gh api "repos/OWNER/REPO/actions/runs?head_sha=$HEAD_SHA&per_page=20" \
  --jq '[.workflow_runs[] | select(.name == "PR Quality Gates")] | .[0].id')

# Re-run it
gh api repos/OWNER/REPO/actions/runs/$RUN_ID/rerun -X POST
```

Wait ~2 minutes, then re-check `gh pr view N --json mergeStateStatus,reviewDecision`. Expected result: `{"mergeStateStatus":"CLEAN", "reviewDecision":"APPROVED"}`.

> **Why the rerun works:** `gh run rerun` on the latest run re-reads the current reviewer list. By that point Copilot has submitted its review, so it's no longer in `requested_reviewers` and auto-approve proceeds. See also [CI Re-runs Replay the Same Commit](#ci-re-runs-replay-the-same-commit) — use the LATEST run id (not an older failed one) so the rerun executes against current HEAD.

### Prevention

Pick one of these patterns when authoring or updating a `pr-quality.yml` / auto-approve workflow. See [`../assets/pr-quality.yml.template`](../assets/pr-quality.yml.template) for the baseline.

**Option A — also trigger on review submission (simplest):**

```yaml
on:
    pull_request_target:
        types: [opened, synchronize, reopened]
    pull_request_review:
        types: [submitted, dismissed]
```

When Copilot submits its review, the workflow re-fires and now sees an empty `requested_reviewers` list. This is the lowest-effort fix and works for most solo-maintainer setups.

**Option B — poll with retry inside the approval step (race-free, slower):**

Before approving, poll `requested_reviewers` until it's empty or a timeout elapses. Typical timeout: 5 minutes. Use this when Copilot reviews are slow or when missed-approval events are expensive (e.g. repos with tight merge SLOs).

**Option C — wait for Copilot explicitly:**

Gate the approval step on `github.event.review.user.login == 'copilot-pull-request-reviewer[bot]' && github.event.review.state != 'changes_requested'` in a `pull_request_review`-triggered job. Race-free but fires only after Copilot posts — not useful when Copilot isn't actually assigned to the PR.

**Do NOT** "fix" this by dropping `required_approving_review_count` to `0` — that loses the OpenSSF Scorecard Code-Review point and removes the audit trail that shows a deliberate approval happened.

## Post-Merge Review Sweep

**Symptom:** you admin-merge a PR that was CLEAN, then hours/days later `gh api graphql` shows unresolved review threads on it. The reviewer posted comments AFTER the merge landed.

**Why this happens:**

1. Admin-merging bypasses the "all threads resolved" check that a normal merge would enforce. A Copilot / human review that was still being authored at merge time lands afterwards.
2. Automated reviewers (GitHub Copilot, Advanced Security code-scanning, gosec/semgrep via reviewdog) often post on the final commit AFTER CI finishes — which can be after the merge.
3. In a batch workflow (e.g. closing out a multi-repo rollout), you move on to the next PR before the previous one settles.

**Consequences:** legitimate review findings go unanswered. If the finding was substantive (correctness bug, dead code, doc drift) it silently ships.

**Sweep process — run at the end of any batched-merge session:**

```bash
# List every PR you merged + check unresolved threads on each.
prs=(
  "owner/repo1#123"
  "owner/repo2#456"
  ...
)
for pr in "${prs[@]}"; do
  R="${pr%#*}"; N="${pr#*#}"
  OWNER="${R%/*}"; NAME="${R#*/}"
  u=$(gh api graphql -f query="{
    repository(owner: \"$OWNER\", name: \"$NAME\") {
      pullRequest(number: $N) {
        reviewThreads(first: 100) { nodes { isResolved } }
      }
    }
  }" | jq '[.data.repository.pullRequest.reviewThreads.nodes[]
            | select(.isResolved == false)] | length')
  [ "$u" -gt 0 ] && echo "UNRESOLVED: $pr ($u)"
done
```

`reviewThreads(first: 100)` covers GitHub's per-page maximum. Paginate with `pageInfo { hasNextPage endCursor }` + `after:` for PRs that might exceed 100 threads (long-running PRs on hot files).

For each unresolved thread:

1. Read the initial comment body via `reviewThreads(first: 100) { nodes { id isResolved comments(first: 1) { nodes { author { login } body } } } }`. Bump `comments(first:)` or paginate if you need follow-up replies on the same thread rather than just the initiating comment.
2. If valid → open a follow-up PR that addresses it, referencing the PR + thread by URL in the commit message.
3. Reply on the thread using the GraphQL mutations in [`gh-cli-reference.md`](./gh-cli-reference.md): `addPullRequestReviewThreadReply` + `resolveReviewThread`.
4. If not valid (false positive, design-intent) → reply with the reasoning (cite evidence — tested behavior, design docs, etc.) then resolve.

**Don't silently dismiss review threads.** Even for false positives, leave a reply explaining why so the next person who opens the PR sees the decision.

**Re-sweep after follow-up PRs merge.** Copilot often reviews the follow-up PR itself and posts new threads. The sweep isn't one-shot — run it again until the count hits zero across all touched PRs.

### Wait for Copilot Before Merging (prevents the cascade)

Copilot's review is **asynchronous**: it usually lands 1–3 min after the PR opens, sometimes longer on a busy day. If you enable `--auto --merge` the instant CI passes, you merge *before* Copilot has reviewed — and the review lands on an already-merged PR, which then needs a follow-up PR to address. Copilot reviews that follow-up too, so the same race repeats. A single round of non-trivial review can easily cascade to 5–6 follow-up PRs.

**Prevention — poll for Copilot before enabling auto-merge:**

```bash
# Wait up to 5 min for Copilot's review to appear. If it never does
# (skill-only docs PRs, repos without Copilot review enabled), the loop
# exits on timeout and you proceed.
for _ in $(seq 1 30); do
  reviewed=$(gh pr view "$PR" --repo "$REPO" --json reviews --jq '
    [.reviews[] | select(.author.login == "copilot-pull-request-reviewer")] | length')
  [ "$reviewed" -ge 1 ] && break
  sleep 10
done

# Now address any unresolved threads, THEN enable auto-merge.
gh pr merge "$PR" --repo "$REPO" --auto --merge
```

**Or enforce via branch protection:** add `copilot-pull-request-reviewer` as a required reviewer so branch protection blocks merge until the review exists. GitHub's UI for this is under *Settings → Branches → Branch protection rules → Require review from Code Owners / specific reviewers*; for rulesets, set `required_pull_request_reviews.required_approving_review_count >= 1` with `dismiss_stale_reviews_on_push: true`. Note that *requested* isn't the same as *approved* — see [merge-strategy.md](./merge-strategy.md) on blocking on pending reviews.

**If you still cascade**, expect it: budget 2–3 sweep rounds mentally rather than claiming "done" after the first merge. The Copilot-review → fix → merge → Copilot-reviews-the-fix loop is the norm on non-trivial text changes, not the exception.

### Validate Copilot Suggestions Before Applying

Copilot occasionally suggests syntactically invalid or semantically wrong code. Recent examples from this fleet:

- **`?:` ternary** in a GitHub Actions expression — not supported; GHA expressions use `&&` / `||` chains
- **`inputs.make_latest`** in a workflow that triggers on both `push.tags` and `workflow_dispatch` — the `inputs` context is undefined on `push` events and raises *"Unrecognized named-value: 'inputs'"*; use `github.event.inputs.*` for safety across events

Treat suggestions as reviewer *input*, not ground truth. Read the code, verify against docs (see [workflow-bash-patterns.md](./workflow-bash-patterns.md) for the GHA expression specifics), and apply in the form that's actually correct. Reply with your adjusted reasoning on the thread rather than silently applying a broken suggestion and having to patch it two sweeps later.

## CI Annotations — Always Check Before Declaring a PR Clean

CI checks can report `success` at the status-run level while still emitting **warning annotations** (typical for actionlint / shellcheck via reviewdog, CodeQL deprecation notices, YAML-lint). These annotations don't show up in `gh pr checks` or in the PR summary page — they only appear on the job's detail page or on the Files-Changed tab. Declaring a PR "clean" based on `gh pr checks` alone leaves real findings un-addressed.

**Check explicitly:**

```bash
# Annotations on a specific check run:
gh api repos/OWNER/REPO/check-runs/CHECK_RUN_ID/annotations --jq \
  '.[] | {message, annotation_level, path, start_line}'

# All check runs for a commit that have any annotations:
gh api "repos/OWNER/REPO/commits/SHA/check-runs" --jq \
  '.check_runs[] | select(.output.annotations_count > 0) |
   {name, annotations: .output.annotations_count}'
```

**Make warnings blocking.** reviewdog-based linters default to posting warnings that don't fail the workflow. Configure them to fail:

```yaml
- uses: reviewdog/action-actionlint@v1   # or -shellcheck, -yamllint, etc.
  with:
    fail_level: error
```

`fail_level: error` is the modern input; the deprecated `fail_on_error` + `level` combination still works but is going away. When a new reviewdog-based linter is added, grep the caller for `fail_level:` and set it to `error` up front — otherwise real findings silently accumulate.

## CI Re-runs Replay the Same Commit

`gh run rerun <run-id>` **re-executes the ORIGINAL commit SHA**, not `HEAD`. If you push a fix and re-run a failed old workflow, the rerun still fails against the pre-fix code.

**Right way:** push the fix, then either wait for the automatic run triggered by the push, or re-run the LATEST run:

```bash
# Latest run ID for a workflow on a branch:
gh api "repos/OWNER/REPO/actions/runs?per_page=5" --jq \
  '.workflow_runs[] | select(.name == "CI") | {id, head_sha: .head_sha[:7]}' \
  | head -1

gh api repos/OWNER/REPO/actions/runs/RUN_ID/rerun -X POST
```

## `mergeStateStatus: BLOCKED` — Check Required vs Non-Required Checks First

`BLOCKED` does **not** mean a check failed — most often it means required checks are still **pending**. Before diagnosing a PR as blocked by a specific tool, compare the failing check against the branch's *required* set. A red **non-required** check never blocks merge.

Real case (2026-07-18): two bump PRs showed `mergeStateStatus: BLOCKED` with `copilot-pull-request-reviewer` at `conclusion: failure` — the failure body was *"Copilot was unable to review this pull request because the user who requested the review has reached their quota limit."* That check was **not** in `required_status_checks`, so both PRs auto-merged the moment the required set (Skill Validation, composer-audit, gitleaks, DCO, …) went green. Reporting them as "Copilot-blocked" was wrong.

This holds even when a `copilot_code_review` rule is active on the branch — that rule requests a review, it does not gate the merge. See "A quota-limited Copilot review does not block the merge" in `merge-strategy.md`.

```bash
# The required set (the ONLY checks that can BLOCK):
gh api repos/OWNER/REPO/branches/main/protection \
  --jq '.required_status_checks.contexts'

# A failing check NOT in that list is advisory — it does not gate merge.
# BLOCKED + all required checks green/pending → wait, don't intervene.
```

Corollary: a quota-exhausted Copilot review returns `conclusion: failure`, not `neutral` — treat "failure" on an advisory reviewer check as noise, not a code problem. Never reach for `--admin` to "unblock" it.

## Merge Queue Behavior and Pitfalls

### Sequential Processing

GitHub's merge queue processes PRs **one at a time**:

- Full CI runs for each PR before it merges
- Force-pushing a queued PR re-triggers CI from scratch and resets its position
- When the preceding PR merges, queued PRs behind it are effectively **rebased behind** — they must be rebased on the new `main`, force-pushed, and re-queued

### Force Push + Stale Review Dismissal Interaction

Rebasing before re-queuing triggers stale review dismissal, which cascades into an auto-approve requirement:

1. You force-push the rebased branch
2. `dismiss_stale_reviews_on_push: true` clears the previous approval
3. Auto-approve workflow must re-run to create a fresh approval
4. **Old review threads survive force push** — threads created against now-obsolete commits are still tracked by GitHub's conversation resolution requirement and still block merge

Explicitly resolve stale threads via GraphQL before re-queuing:

```bash
# Find thread IDs
gh api repos/OWNER/REPO/pulls/NUMBER/comments --jq '.[] | {id, node_id, body}'

# Resolve each thread
gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "PRRT_xxx"}) { thread { isResolved } } }'
```

### Multi-PR Workflow Pattern

When landing multiple dependent PRs, expect the dependent PRs to need rebasing after each merge:

```
1. Queue PR1 and PR2 (PR2 depends on PR1)
2. PR1 merges
3. PR2 is now behind — must be rebased:
   git fetch origin
   git rebase origin/main
   git push --force-with-lease
4. Force push dismisses approval → wait for auto-approve to re-run (or re-trigger it)
5. Resolve any stale review threads from old commits
6. Re-queue PR2:
   gh pr merge NUMBER --merge --auto
```

**Checklist before re-queuing after rebase:**

| Step | Command |
|------|---------|
| Rebase on latest main | `git rebase origin/main && git push --force-with-lease` |
| Trigger auto-approve | Wait for `pr-quality.yml` to run, or re-run it manually |
| Resolve stale threads | GraphQL `resolveReviewThread` for each stale thread |
| Re-enable auto-merge | `gh pr merge NUMBER --merge --auto` |

### Troubleshooting Merge Queue Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| PR exits queue after force push | CI reset on new push | Expected — wait for CI to pass again |
| PR stuck after preceding PR merged | PR is now behind `main` | Rebase, force push, re-queue |
| `REVIEW_REQUIRED` after rebase | Stale review dismissal cleared approval | Re-run auto-approve workflow |
| Unresolved threads block merge | Old threads survive rebase | Resolve via GraphQL `resolveReviewThread` |
| Armed (`autoMergeRequest` set) but never enters the queue | First `--auto` armed auto-merge without enqueuing — checks are green, no threads, yet `mergeQueue.entries` is empty and the PR just sits | Re-issue `gh pr merge NUMBER --auto`; it reports "already queued to merge" and the entry then shows `AWAITING_CHECKS`. Confirm with the [`mergeQueue.entries` GraphQL query](#verifying-a-pr-actually-merged-enqueue--merged) — do not assume arming enqueued it |

### Verifying a PR Actually Merged (enqueue ≠ merged)

On a merge-queue repo, `gh pr merge … --merge` (or `--auto`) only **enqueues** the PR —
the command returns success immediately and the PR is **still open**. Don't report
"merged" off the exit code; the queue runs its own CI first and merges later (minutes,
if the queue runs the full matrix). It can also silently stall.

The queue runs CI on a synthetic branch named `gh-readonly-queue/<base>/pr-<N>-<sha>`.
To find that CI and confirm the PR lands:

```bash
# Is it queued, and at what position?
gh api graphql -f query='query($owner:String!,$repo:String!){
  repository(owner:$owner,name:$repo){
    mergeQueue { entries(first:10){ nodes{ position state pullRequest{ number } } } } } }' \
  -f owner=OWNER -f repo=REPO \
  --jq '.data.repository.mergeQueue?.entries?.nodes[]? // empty'

# Watch the queue's own CI (note the merge_group event, not pull_request)
gh run list --repo OWNER/REPO --event merge_group --limit 5 \
  --json status,conclusion,headBranch,name \
  --jq '.[] | select(.headBranch|test("pr-<N>-")) | "\(.status)/\(.conclusion // "-") \(.name)"'

# Confirm it actually merged (state MERGED + branch gone)
gh pr view <N> --repo OWNER/REPO --json state,mergedAt,mergeCommit \
  --jq '{state, mergedAt, mergeCommit: (.mergeCommit?.oid // "none")}'
```

Poll `state == "MERGED"` (or a `merge_group` run concluding `failure`) before declaring
done — green checks on the PR head are necessary but not sufficient once a queue is in
play.

## Signed Commits and Merge Strategy Compatibility

GitHub can only auto-sign **merge commits** and **squash merges**. It **cannot** auto-sign rebased commits. If branch protection requires signed commits and the workflow uses `--rebase`, merges fail with:

> `Base branch requires signed commits. Rebase merges cannot be automatically signed by GitHub.`

### Auto-detect Merge Strategy

Instead of hardcoding `--merge`, `--squash`, or `--rebase`, auto-detect from repo settings:

```bash
STRATEGY=$(gh api "repos/${{ github.repository }}" --jq '
  if .allow_squash_merge then "--squash"
  elif .allow_merge_commit then "--merge"
  elif .allow_rebase_merge then "--rebase"
  else "--squash" end')
gh pr merge --auto $STRATEGY "$PR_URL"
```

**Priority order:** squash > merge > rebase. Squash is preferred because:
1. Works with signed commit requirements (GitHub can sign squash merges)
2. Clean history for single-commit dependency PRs
3. Most universally compatible

### Enabling Squash Merge on Repos

If a repo only allows rebase merges and requires signed commits, enable squash:

```bash
gh api repos/OWNER/REPO -X PATCH -f allow_squash_merge=true
```

## Workflow File Changes Cannot Be Auto-merged

PRs that modify `.github/workflows/` files cannot be merged by `GITHUB_TOKEN` — it lacks the `workflows` permission scope. This commonly affects Dependabot/Renovate PRs that update GitHub Actions versions.

**Detection:** The `auto-merge-deps.yml` workflow should check for workflow file changes before attempting merge:

```bash
WORKFLOW_FILES=$(gh pr diff "$PR_URL" --name-only | grep -E '^\.github/workflows/' || true)
if [ -n "$WORKFLOW_FILES" ]; then
  echo "PR modifies workflow files — requires manual merge"
fi
```

**Resolution:** Merge manually using a local clone with SSH authentication:

```bash
# For repos without branch protection (direct push allowed):
git clone --depth=5 git@github.com:OWNER/REPO.git /tmp/REPO
cd /tmp/REPO
BRANCH=$(gh pr view NUMBER --repo OWNER/REPO --json headRefName --jq '.headRefName')
git fetch origin "$BRANCH"
git merge --no-ff -S --signoff "origin/$BRANCH" -m "Merge pull request #NUMBER from OWNER/$BRANCH"
git push origin MAIN_BRANCH
```

**For repos with multiple workflow PRs:** Merge sequentially — each subsequent PR may need rebasing after the previous one merges since they typically touch the same workflow files.

## Batch Auto-merge for Multiple PRs

When enabling auto-merge across many repos/PRs at once:

```bash
gh pr merge NUMBER --repo OWNER/REPO --auto --merge
```

**Limitations discovered:**
- GitHub may reject auto-merge on a second PR in the same repo if the first is still pending: "Pull request Auto merge is not allowed for this repository"
- This is typically a timing issue — once the first PR merges, re-enable auto-merge on remaining PRs
- Some repos need the "Allow auto-merge" setting enabled in repository settings first
- Repos where you lack admin/maintainer access will fail with permission errors

## Archived Repos — Handle Dependabot/Renovate PRs with Care

Archived repositories still receive Dependabot/Renovate PRs, but you cannot
merge them or enable auto-merge — writes are blocked, and auto-merge fails with a
permission error. Don't fight it:

1. **Unarchive** the repo.
2. **Close** the PR (or merge it, if the update is genuinely wanted).
3. **Re-archive** the repo.

Before any batch auto-merge sweep across an org, filter archived repos out first
so they don't generate noise:

```bash
# gh filters archived repos out server-side:
gh repo list ORG --no-archived --json name --jq '.[].name'
```

Never enable auto-merge on an archived repo — it errors and leaves the PR in a
confusing half-state.

## Recommended Renovate Config for Auto-merge

```json
{
  "extends": ["config:recommended"],
  "automergeType": "pr",
  "platformAutomerge": true,
  "lockFileMaintenance": {
    "enabled": true,
    "schedule": ["before 6am on monday"]
  },
  "packageRules": [
    {
      "matchUpdateTypes": ["patch", "minor", "pin", "digest"],
      "automerge": true
    }
  ]
}
```

**Key settings:**
- `platformAutomerge: true` - Renovate enables auto-merge (uses bypass permissions)
- `lockFileMaintenance` - Handles lock file updates via PR (not direct push)

**The `renovate/stability-days` check (produced by the `minimumReleaseAge` config option, formerly `stabilityDays`) keeps an armed PR `UNSTABLE` on purpose.** A Renovate PR with auto-merge armed, every real check green, and only `renovate/stability-days` PENDING is not stuck — the pending status *is* the supply-chain delay, and Renovate completes the merge when the window elapses. `mergeStateStatus` shows `UNSTABLE` the whole time. Leave it alone; merging by hand defeats the deliberate release-age gate.

## Canonical Auto-merge Workflow Template

```yaml
name: Auto-merge dependency PRs

on:
  pull_request_target:
    types: [opened, synchronize, reopened]

permissions:
  contents: write
  pull-requests: write

jobs:
  auto-merge:
    runs-on: ubuntu-latest
    if: >-
      github.event.pull_request.user.login == 'dependabot[bot]' ||
      github.event.pull_request.user.login == 'renovate[bot]'
    steps:
      - name: Approve PR
        env:
          PR_URL: ${{ github.event.pull_request.html_url }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: gh pr review --approve "$PR_URL"

      - name: Enable auto-merge
        env:
          PR_URL: ${{ github.event.pull_request.html_url }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          REPO: ${{ github.repository }}
        run: |
          STRATEGY=$(gh api "repos/$REPO" --jq '
            if .allow_squash_merge then "--squash"
            elif .allow_merge_commit then "--merge"
            elif .allow_rebase_merge then "--rebase"
            else "--merge" end')
          gh pr merge --auto "$STRATEGY" "$PR_URL"
```

### Key Design Decisions

- **`pull_request_target`**: Required for bot PRs — `pull_request` runs with read-only tokens for fork-like contexts
- **`user.login`**: Immutable PR author field — `github.actor` changes when humans re-run workflows
- **`--auto`**: Respects branch protection, merge queues, and required checks — direct merge bypasses these
- **Dynamic strategy**: Repos may only allow specific merge methods — hardcoding breaks when config changes

## Branch Protection for Auto-merge

```bash
# Check required checks vs actual check names
gh api repos/OWNER/REPO/branches/main/protection/required_status_checks --jq '.checks[].context'

# Check code owner requirement (should be false for auto-merge)
gh api repos/OWNER/REPO/branches/main/protection/required_pull_request_reviews --jq '.require_code_owner_reviews'

# Check bypass apps
gh api repos/OWNER/REPO/branches/main/protection/required_pull_request_reviews --jq '.bypass_pull_request_allowances.apps[].slug'

# Fix: Disable code owner reviews, add bypass apps
gh api repos/OWNER/REPO/branches/main/protection/required_pull_request_reviews -X PATCH \
  --input - << 'EOF'
{
  "require_code_owner_reviews": false,
  "required_approving_review_count": 1,
  "bypass_pull_request_allowances": {
    "apps": ["dependabot", "renovate"]
  }
}
EOF
```

## Auto-merged PRs leave the base branch without post-merge CI

A merge performed with `GITHUB_TOKEN` — which is what the auto-merge workflow
uses, directly or via `gh pr merge --auto` — does not trigger further workflow
runs. GitHub suppresses workflow triggers for events created by that token, so
the `push` to the base branch produces nothing. Measured on one repository:

| Merge commit | Merged by | push-triggered CI runs on `main` |
|---|---|---|
| `699df245` | maintainer (`gh pr merge`) | 5 |
| `162c57b7` | maintainer (`gh pr merge`) | 5 |
| `ddc3810a` | auto-merge workflow | **0** |
| `5a513fe1` | auto-merge workflow | **0** |
| `875fb1a4` | auto-merge workflow | **0** |
| `c61d560f` | auto-merge workflow | **0** |

Rule out the cheaper explanation first — a `paths`/`paths-ignore` filter on the
`push` trigger produces the same symptom:

```bash
gh api repos/$R/contents/.github/workflows/ci.yml --jq .content | base64 -d | yq '.on'
```

On its own the missing run is tolerable, because the PR's own CI covered the
head commit. It becomes a hole when combined with a non-strict status-check
policy: the PR may have been tested against a `main` that has since advanced,
and nothing ever tests the combination.

```bash
gh api repos/$R/rules/branches/main \
  --jq '.[]|select(.type=="required_status_checks")|.parameters'
# strict_required_status_checks_policy: false  →  stale PRs may merge untested
```

Two fixes, in increasing strength:

1. **`strict_required_status_checks_policy: true`** — one flag. GitHub holds the
   merge until the branch is current, so the tested tree equals the merged tree
   and the missing post-merge run stops mattering. Cost: every base-branch push
   invalidates open PRs, which then need an update (`allow_update_branch: true`
   and the bots handle their own). Reversible with one API call — back the
   ruleset up first (`gh api repos/$R/rulesets/$ID > backup.json`).
2. **Merge queue** — tests the merge *result* before it lands, and covers
   maintainer merges too. Needs a `merge_group:` trigger in the CI workflow and
   queue configuration in the ruleset.

Do **not** try to bolt a post-merge `workflow run` dispatch onto the auto-merge
job. `workflow_dispatch` and `repository_dispatch` are indeed the documented
exceptions to the `GITHUB_TOKEN` suppression, but when the base branch has
required checks the job takes the native path — `gh pr merge --auto` followed by
`exit 0` — and finishes long before GitHub performs the merge. There is no point
in that job at which the merge commit exists.

## Auto-merge can land a bot PR while you are still fixing it

In a repo with an auto-merge deps workflow, pushing a fix to a bot PR's branch
starts a clock: as soon as the required checks go green the workflow merges,
with no further confirmation. Two dependency PRs merged four minutes apart while
a correction to one of them was still being verified locally — the flawed commit
reached the base branch and needed a follow-up PR instead of an amend.

Treat "pushed and green" as "merged" on those branches:

- Finish verification *before* the push that turns the PR green, not after.
- Once it is green, plan on a follow-up PR against the base branch. Amending and
  force-pushing races the workflow and fails with `stale info` once the branch
  is deleted post-merge.
- Check whether the merge already happened before diagnosing a push failure:
  `gh pr view $PR --repo $R --json state,mergedAt,mergedBy`.
