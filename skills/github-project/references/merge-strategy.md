# Merge Strategy for Signed Commits

This guide explains how to configure GitHub repositories that require both signed commits and clean git history.

## The Problem

GitHub's branch protection offers two relevant settings that conflict:

| Setting | Effect |
|---------|--------|
| `required_signatures` | All commits on protected branch must be signed |
| `required_linear_history` | Only squash or rebase merges allowed (no merge commits) |

**The conflict:** GitHub cannot sign commits during squash or rebase merge operations. When `required_linear_history` is enabled, GitHub rewrites commits server-side, but cannot sign them with your GPG/SSH key.

## The Solution

Use **local rebase + merge commit**:

1. Developers rebase their PR branch locally (signing commits with their key)
2. Force-push the rebased branch
3. Merge via merge commit (GitHub signs the merge commit with its key)

This gives you:
- ✅ Clean, linear history on feature branches
- ✅ Clear merge points on main branch
- ✅ All commits verified (developers sign feature commits, GitHub signs merge commits)

## Repository Settings

Configure via API:

```bash
gh api repos/{owner}/{repo} -X PATCH \
  -f allow_merge_commit=true \
  -f allow_rebase_merge=true \
  -f allow_squash_merge=false
```

| Setting | Value | Reason |
|---------|-------|--------|
| `allow_merge_commit` | `true` | Required for signed commits workflow |
| `allow_rebase_merge` | `true` | GitHub requires at least one of squash/rebase |
| `allow_squash_merge` | `false` | Destroys individual commit history and signatures |

**Note:** GitHub requires at least one of `allow_squash_merge` or `allow_rebase_merge` to be true. Keep `allow_rebase_merge` enabled but don't use it for PRs requiring signatures.

## Branch Protection Settings

Configure via API:

```bash
gh api repos/{owner}/{repo}/branches/main/protection -X PUT \
  --input - << 'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["ci"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "required_linear_history": false,
  "required_signatures": true,
  "required_conversation_resolution": true
}
EOF
```

| Setting | Value | Reason |
|---------|-------|--------|
| `required_signatures` | `true` | Enforces signed commits |
| `required_linear_history` | `false` | **Must be false** - blocks merge commits |
| `required_conversation_resolution` | `true` | All review threads must be resolved before merge |

## Developer Workflow

### Before Opening PR

```bash
# Ensure commits are signed
git config commit.gpgsign true
```

### Before Merging

```bash
# 1. Fetch latest main
git fetch origin

# 2. Rebase on main (re-signs commits)
git rebase origin/main

# 3. Force-push rebased branch
git push --force-with-lease
```

### Merging

```bash
# Use merge commit strategy
gh pr merge <number> --merge
```

## Auto-Merge Configuration

Auto-merge works with signed commits **only when using merge commit strategy**.

| Strategy | Compatible | Reason |
|----------|------------|--------|
| Merge commit | ✅ | GitHub signs merge commit with its key |
| Rebase | ❌ | GitHub cannot sign rewritten commits |
| Squash | ❌ | GitHub cannot sign squashed commit |

When configuring auto-merge workflows, ensure they use `--merge`:

```yaml
- name: Enable auto-merge
  run: gh pr merge --auto --merge "$PR_NUMBER"
```

## How GitHub Signing Works

When you merge via the GitHub UI or API with merge commit:

1. **Feature branch commits**: Retain original GPG/SSH signatures from developers
2. **Merge commit**: Signed by GitHub's web-flow key (`noreply@github.com`)

Both are marked as "Verified" in the GitHub UI:
- Developer commits show the developer's GPG key
- Merge commits show "Verified" with GitHub as the signer

### "Update branch" and signing (who has to act on "branch out of date")

- **"Update branch" (merge variant)**: the update-merge commit is created and signed by GitHub's web-flow key — satisfies "require signed commits" with zero author involvement. In a squash-merge repo the update commit is squashed away at landing anyway.
- **"Update with rebase" button / rebase merges**: GitHub **cannot re-sign rewritten commits** — fails on signed-commit-protected repos.
- **Local rebase**: signature verification is against the **committer**, not the author. Anyone with head-branch push access (author, or maintainers when "Allow edits from maintainers" is on) can `git rebase -S && git push --force-with-lease`, re-signing with *their own* verified key — authorship and `Signed-off-by` trailers survive. The original author does not have to be the one who rebases.

## Stale-green merge refs: two green PRs can still break main

A PR's `pull_request` checks run against a **snapshot merge ref** (`refs/pull/N/merge` = PR + base *at the moment the run starts*). GitHub never re-runs a PR's checks when the base branch moves afterward — the green badge silently goes stale (observed: an 8-day-old green used to merge). Two PRs that are **textually disjoint** (no git conflict, `MERGEABLE`) can be **semantically conflicting** — e.g. one adds a test fixture rendered from a template the other PR changes. Whichever merges second turns main red, and every open PR then inherits the failure through its merge ref.

Mitigations, in increasing strength:

1. **Required checks + strict up-to-date.** `strict: true` ("Require branches to be up to date") applies **only to the checks listed in `required_status_checks`** (`checks` is the canonical field; `contexts` is its deprecated mirror) — with an empty list it is a **complete no-op**, and red CI does not block merging at all. Audit the flag and both list fields together:

   ```bash
   gh api repos/OWNER/REPO/branches/main/protection \
     --jq '{strict: (.required_status_checks?.strict // false),
            contexts: (.required_status_checks?.contexts // []),
            checks: (.required_status_checks?.checks // [])}'
   # strict=true + empty contexts AND checks → the flag does nothing; populate the checks list
   ```

2. **Merge queue.** Tests `latest main + queued PRs + this PR` (`merge_group` event) before landing; a semantically conflicting PR is ejected instead of breaking main. Prerequisites: workflows must add a `merge_group:` trigger (or checks never report and the queue stalls), and the queue only gates **required** checks — an empty contexts list makes it vacuous too.

Neither catches a semantic conflict no test covers. Post-merge push CI on the default branch stays the last line of defence — keep it.

## Enabling a merge queue

The classic branch-protection REST API does **not** expose a merge-queue toggle, so a repository **ruleset** is the only scriptable path. The `merge_queue` rule is **repository-level only** — an org-level ruleset rejects it, so a queue is always a per-repo decision.

```bash
gh api -X POST repos/OWNER/REPO/rulesets --input - <<'JSON'
{
  "name": "merge-queue-main",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [
    { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }
  ],
  "conditions": { "ref_name": { "include": ["refs/heads/main"], "exclude": [] } },
  "rules": [
    {
      "type": "merge_queue",
      "parameters": {
        "merge_method": "SQUASH",
        "grouping_strategy": "ALLGREEN",
        "check_response_timeout_minutes": 30,
        "max_entries_to_build": 5,
        "max_entries_to_merge": 5,
        "min_entries_to_merge": 1,
        "min_entries_to_merge_wait_minutes": 5
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [
          { "context": "Tests (8.2)", "integration_id": 15368 }
        ]
      }
    }
  ]
}
JSON
```

Parameters and gotchas:

- `merge_method`: `SQUASH` | `MERGE` | `REBASE`. The queue owns the merge method for every entry, so per-PR choice disappears. `SQUASH`/`MERGE` stay GitHub-signed; `REBASE` re-creates commits **unsigned** — on a signed-commits branch, prefer `SQUASH`/`MERGE`.
- `grouping_strategy`: `ALLGREEN` (every queued entry must pass) or `HEADGREEN` (only the group's head commit — all changes combined — must pass). `ALLGREEN` is the safe default; `HEADGREEN` only saves CI under contention.
- `check_response_timeout_minutes`: a required check that has not reported by then is treated as **failed** and the entry is ejected. Size it above one CI cycle.
- `min_entries_to_merge` + `min_entries_to_merge_wait_minutes`: the wait only holds a smaller-than-minimum group. With `min_entries_to_merge: 1` **the wait value is inert** — a single entry already meets the minimum, so it never batches. Only raise the minimum (and the wait) if you actually want to batch, e.g. a Dependabot burst.
- `required_status_checks[].integration_id: 15368` pins each required context to the **GitHub Actions app**, so another app cannot satisfy (spoof) the context. Every required-check workflow must also carry an `on: merge_group:` trigger, or its checks never report on the queue and every group times out.
- Enable the queue in **one surface only**. If a classic branch-protection rule already gates the branch, leave reviews/conversation-resolution there and put the queue + required checks in the ruleset — then set the classic `strict` ("require branches up to date") flag to **false**: the queue makes it redundant and it otherwise forces author-side update-branch churn.
- `enforcement: "evaluate"` dry-runs the ruleset (logs what it *would* block) without enforcing — a soft launch before `active`. Rollback is one call: delete the ruleset (or set `enforcement: "disabled"`) and restore the classic `strict` flag.

## Troubleshooting

### Diagnose `mergeStateStatus: BLOCKED` before naming a cause

When a PR is `BLOCKED`, **do not assert a cause** (and never reflexively say "blocked on review" / "waiting for a reviewer") until you have fetched the effective ruleset and named the exact gating rule. `mergeStateStatus` alone does not tell you why; a human-approval gate is almost never the reason. The PR page states the reason in plain text ("All comments must be resolved", "Required statuses must pass") — read it, and the same facts are queryable.

The single most common cause is **unresolved review threads** (including from bots) — check that first:

```bash
# reviewThreads is ONLY available via GraphQL — it is NOT a valid `gh pr view --json` field
gh api graphql -f query='query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){pullRequest(number:$pr){
    reviewThreads(first:50){nodes{id isResolved}}}}}' -f owner=O -f repo=R -F pr=N \
  --jq '[.data.repository.pullRequest?.reviewThreads?.nodes[]?|select(.isResolved==false)]|length'
```

Passing `reviewThreads` to `gh pr view --json` errors "Unknown JSON field" — a merge-gate script that does this silently fails open and allows every merge. If the unresolved count is >0, address each comment, reply citing the fix commit, resolve. Only if it is 0 do you inspect the ruleset:

```bash
gh api repos/{owner}/{repo}/rules/branches/{BASE} --jq 'group_by(.type)[]|{type:.[0].type,n:length}'
gh pr view N --json reviewDecision,mergeStateStatus,statusCheckRollup
```

Then name the specific rule (`copilot_code_review`, `required_status_checks`, `non_fast_forward`, merge queue, …). A `pull_request` rule with `reviewDecision: ""` means there is **no human-approval requirement at all**.

**BLOCKED with every visible check green: look for a second, still-running check suite.** `gh run list --commit $SHA` only shows runs with known triggers (push, pull_request, schedule, dispatch) — GitHub-managed **default code scanning and Copilot review run as "dynamic" events and never appear there**. Check-runs are equally misleading for a different reason: the API does include in-progress runs, but a *second* suite from the same app may not have created any check runs yet — so every required context name shows green while that suite is still in progress, and it is the actual blocker. Before concluding the block is structural, list the suites:

```bash
gh api "repos/{owner}/{repo}/commits/{SHA}/check-suites" \
  --jq '.check_suites[] | "\(.status)/\(.conclusion // "—")\t\(.app.slug)\trun_count=\(.latest_check_runs_count)"'
```

An `in_progress` row here with all visible checks green means the BLOCKED state is transient — wait for that suite instead of diagnosing rulesets. (A suite that never concludes is the adjacent, different case — see "CodeQL default-setup check queued forever" below.)

### Never merge while a review is announced or in flight

Once a reviewer is requested or has *started* (by you, a ruleset, or automation), its pendency blocks the merge until it resolves — regardless of `mergeStateStatus`. `CLEAN` is necessary but never sufficient: a `copilot_code_review` ruleset with `review_on_push: false` reports `CLEAN` off an *earlier* commit's review while a new one is still running, and a reviewer that has *started* drops off the request list without submitting — so `reviewRequests: []` is **not** "all clear". Check the timeline / pending-review state, not just `reviewRequests`. Do not request or re-request a reviewer as a pre-merge step (announcing one commits you to waiting). The absence of a review is not itself a blocker — you cannot require a review to *exist* (bots fail, decline, or are unconfigured) — but an *announced* one must be allowed to finish.

### CodeQL default-setup check queued forever on a diff with nothing to analyze

CodeQL **default setup** (app `github-advanced-security`, check name `CodeQL`)
can sit `queued` indefinitely on a PR whose diff contains **no files of any
configured language** — e.g. default setup configured for `actions` only and a
docs-only diff (`SKILL.md` + `plugin.json`). Instead of auto-passing, the check
never concludes, and `mergeStateStatus` stays `UNSTABLE` (or `BLOCKED` if the
check is required). Verified behaviors (2026-08-03, two wedged suites on one PR):

- `POST /repos/{owner}/{repo}/check-suites/{check_suite_id}/rerequest` returns
  **404** for default-setup suites — there is no workflow run to re-run either.
- **Close/reopen spawns a fresh suite that wedges identically** — the re-run
  has the same nothing-to-analyze diff.
- Diagnose with: `gh api repos/{owner}/{repo}/code-scanning/default-setup`
  (languages) vs. the PR's changed files.

Escape paths, in preference order: (1) if the check is not required, get
explicit human authorization and merge via the REST endpoint
(`gh api -X PUT repos/{owner}/{repo}/pulls/{n}/merge -f merge_method=merge` —
see the section below on REST-vs-GraphQL); (2) touch a file of a configured language so the
analysis has an object; (3) wait — GitHub sometimes expires wedged queued
check-runs after several hours, but neither timing nor outcome is dependable.

### `gh pr merge` falsely reports "base branch policy prohibits the merge"

`gh pr merge` (GraphQL path) can fail with "the base branch policy prohibits the merge" even when every requirement is verifiably satisfied (rollup SUCCESS, signature valid, 0 required approvals, 0 unresolved threads, branch up to date, no blocking rulesets), and `--auto` never fires either. The REST endpoint succeeds immediately on the same head SHA:

```bash
gh api -X PUT repos/{owner}/{repo}/pulls/{n}/merge -f merge_method=merge
```

Use this **only after the merge gate is genuinely verified** — the REST path bypasses whatever GraphQL mis-evaluated, so it must not be used to force past a *real* policy block.

### All merge methods rejected — merge-method ruleset deadlock

When every `gh pr merge --merge/--rebase/--squash` (and REST `PUT .../merge`) returns `"<method> merges are not allowed on this repository"` (HTTP 405) even though `gh api repos/<r> --jq '{allow_merge_commit,allow_squash_merge,allow_rebase_merge}'` shows a method enabled, the cause is a deadlock: an **org-level ruleset** sets `pull_request.allowed_merge_methods`, and the effective allowed set is the **intersection** of that with the repo's `allow_*_merge` flags. If the org allows only `squash` but the repo has `allow_squash_merge: false`, the intersection is empty and nothing merges.

Diagnosis gotcha: `repos/<r>/rules/branches/main` may show a *permissive* list because `orgs/<org>/rulesets` is not listable without org-admin, so the stricter org ruleset is invisible and the contradiction looks like a GitHub bug — it isn't. `--admin` does **not** bypass `allowed_merge_methods` (it only bypasses status checks / required reviews). The only fixes are repo/org-admin actions (enable the org-required method at the repo level, exempt the repo, or adjust the org ruleset). Do not toggle repo merge settings autonomously on an inference — flag it for the owner.

### A quota-limited Copilot review does not block the merge

`copilot_code_review` in a ruleset is an **automation** rule — "automatically request Copilot code review" — not a merge gate. Per [GitHub's docs](https://docs.github.com/en/copilot/how-tos/copilot-on-github/set-up-copilot/configure-automatic-review), Copilot always leaves a *Comment* review, it never counts toward required approvals, and it does not block merging. Its two parameters (`review_draft_pull_requests`, `review_on_push`) only widen *when* the request fires.

So when Copilot is quota-limited and posts `COMMENTED` — *"unable to review … reached their quota limit"* — nothing is gated by it. Observed in `netresearch/t3x-nr-image-optimize` PR #140: the `copilot_code_review` rule was active on `main`, Copilot posted exactly that quota review, `mergeStateStatus` went `CLEAN`, and a plain `gh pr merge --merge` succeeded without `--admin`.

**Never reach for `--admin` on this diagnosis.** If a PR is `BLOCKED` while the Copilot check is red, the cause is elsewhere — find it before escalating:

```bash
# 1. Which rules actually gate this branch? (copilot_code_review is not one)
gh api repos/$R/rules/branches/main --jq '[.[].type]'

# 2. The required contexts — the only checks that can BLOCK
gh api repos/$R/rules/branches/main \
  --jq '.[] | select(.type=="required_status_checks")
        | .parameters.required_status_checks[].context'

# 3. Are approvals required, and is one outstanding?
gh api repos/$R/rules/branches/main --jq '.[] | select(.type=="pull_request")'
gh pr view $PR --repo $R --json reviewDecision,latestReviews
```

The usual real causes: a required check still pending (see "`mergeStateStatus: BLOCKED` — Check Required vs Non-Required Checks First" in `auto-merge-guide.md`), unresolved review threads, or a `pull_request` rule whose required approval is missing because the auto-approve job raced the Copilot review request (see "Auto-Approve Race Condition"). A quota-limited Copilot review is never the reason.

**The real hazard runs the other way.** The gate reads as satisfied while no review happened: the `COMMENTED` review object exists, checks go green, the PR merges — and nothing reviewed the diff. Treat a quota-limited Copilot review as *no review*, and decide on that basis whether the change needs human eyes before merging.

**CLEAN variant — the quota review does NOT always block.** With a ruleset configured `review_on_push: false`, a quota-limited Copilot review (same `COMMENTED` "reached their quota limit" body) can leave `mergeStateStatus: CLEAN` and `gh pr merge` succeeds without `--admin` (observed 2026-07-30, three consecutive PRs on one repo). Do not expect `BLOCKED` as proof of the quota condition — check the review body itself. The risk inverts here: the merge is *allowed* but lands with zero substantive review. Treat the quota review as landed-but-content-free — the merge gate may proceed, but explicitly flag the PR (in the report to the user) for retroactive review once quota resets, instead of letting it merge silently unreviewed.

### SonarCloud PR gate re-attributes pre-existing issues to a refactor

SonarCloud measures "new code" as lines touched by the PR, so mechanical refactors (e.g. method extraction, literal→const swaps) re-attribute pre-existing duplication and uncovered lines to the PR, failing `new_duplicated_lines_density` or `codecov/patch`. Don't resort to test-theater or risky out-of-scope de-duplication inside a behavior-preserving PR. First fix what is genuinely cheap and meaningful (a small unit test for an extracted helper often flips `codecov/project` green). For the structural residue, confirm the gate is **non-required** (`mergeStateStatus: UNSTABLE`, not `BLOCKED`), write a "Quality gate note" section into the PR body naming the metric, the cause, and why it is out of scope, then merge. Style-rule whack-a-mole (each push surfacing the next batch) is best handled by modernizing the whole file in one pass — but verify bulk codemods with the language's own parser (a naive `var`→`const` regex turns `var x;` into invalid `const x;`).


### SonarCloud operational gotchas (onboarding + Automatic Analysis)

- **The project's "Main Branch" slot defaults to `master`** regardless of the GitHub default branch, so first scans of a `main`-repo land on a short-lived branch literally named `main` and the overview claims "master branch has not been analyzed yet". Fix in Project → Administration → Branches: delete the short-lived `main` first (else the rename fails with "name already exists"), rename the Main Branch to `main`, trigger a fresh scan.
- **What Automatic Analysis honors vs. ignores**: `.sonarcloud.properties` file exclusions and inline `// NOSONAR` comments work; `sonar.issue.ignore.multicriteria` rule-ignores are a **no-op** there — don't spend a round-trip on them, use exclusions or NOSONAR.
- **Automatic Analysis (GitHub-App mode) silently ignores `sonar-project.properties`.** The file it honors is **`.sonarcloud.properties`** at repo root (Java-properties syntax), on the analyzed branch; it overrides UI Analysis-Scope settings. For false-positive sensors on template files (e.g. TYPO3 Fluid tripping the HTML sensor), plain `sonar.exclusions=...` removes the files from scope and cannot break analysis — prefer it over disabling sensors or `sonar.issue.ignore.multicriteria`.

### "Merge commits are not allowed on this repository"

**Cause:** `allow_merge_commit` is false in repository settings.

**Fix:**
```bash
gh api repos/{owner}/{repo} -X PATCH -f allow_merge_commit=true
```

### "Base branch requires signed commits. Rebase merges cannot be automatically signed"

**Cause:** `required_linear_history` is true, forcing rebase merge which GitHub cannot sign.

**Fix:**
```bash
gh api repos/{owner}/{repo}/branches/main/protection -X PUT \
  --input - << 'EOF'
{
  ...existing settings...,
  "required_linear_history": false
}
EOF
```

### Auto-merge fails with signature error

**Cause:** Auto-merge configured with rebase or squash strategy.

**Fix:** Update auto-merge workflow to use `--merge` flag instead of `--rebase` or `--squash`.

### Rulesets cannot block merge on a pending review

Neither branch protection nor rulesets support "block merge while any requested reviewer hasn't submitted yet". The options available are adjacent but not equivalent:

| Setting | What it does | Not what you want |
|---|---|---|
| `required_approving_review_count: 1` | Needs **one approval** | Doesn't wait for other requested reviewers |
| `required_review_thread_resolution: true` | Blocks on **unresolved threads** | Doesn't block before any thread is created |

If you need to hold merge until Copilot (or any other requested reviewer) has actually posted its review, the workaround is a custom GitHub Actions status check that queries pending reviewers and fails if any are outstanding — then require that check in branch protection.

```bash
# Example: fail the check if any reviewer — user or team — is still requested.
pending=$(gh api "repos/$REPO/pulls/$PR" \
  --jq '((.requested_reviewers // []) | length) + ((.requested_teams // []) | length)')
if [[ "$pending" -gt 0 ]]; then
  echo "::error::Still waiting on $pending review request(s) (user/team)"
  exit 1
fi
```

### Renaming a CI job orphans its required status check → PR stuck "Expected"

**Every CI step that runs on a PR belongs in `required_status_checks` — advisory checks are decorative.** If a job's result would not stop a merge, the job provides no protection; a "flaky" or "in flux" check gets fixed or removed, not demoted to advisory. When adding a new CI job, add its context name to the ruleset in the same change; when a future shape change (sharding, matrix expansion) will rename the contexts, edit the ruleset twice — once now to lock the current shape, once at the change — rather than deferring the lock.

Required status checks are matched by **exact context name**. Renaming a job — including changing a **matrix value** that appears in the job name (e.g. `PHPStan (8.2, ^14.0)` → `PHPStan (8.2, ^14.3)`) — produces a *new* context name. The old required context no longer reports, so it sits "Expected — Waiting for status to be reported" forever and the PR is `BLOCKED`, even though every job is green.

This is a silent trap: the CI change looks self-contained, but the required-checks list in branch protection / the ruleset still names the old job. Treat the required-checks list as a declared value that must be swept whenever a job name changes.

**The same orphan happens when you *enable a previously-disabled/skipped* matrix job** — and this one is nastier because nothing was renamed. While the job is disabled it still reports its **bare** context (e.g. `ci / Functional Tests SQLite`) as a `skipped`/`neutral` run, which *satisfies* the required check — so the required-checks list looks correct and merges pass. The moment you enable it, GitHub expands that one bare context into N **matrix** contexts (`ci / Functional Tests SQLite (8.2, ^13.4)` … `(8.5, ^14.3)`); the bare required context now has no matching run and the PR is permanently `BLOCKED` — with **every visible check green** (the missing required context does not appear in `gh pr checks`). Diagnose by diffing the ruleset's `required_status_checks[].context` list against the actual `repos/$REPO/commits/$SHA/check-runs[].name` values; the fix is the same ruleset/branch-protection update below (swap the bare context for the matrix-expanded ones). This ALSO is what finally makes a newly-enabled job actually *gate* merges.

```bash
# After renaming any matrixed/required job, update the ruleset's contexts.
# Rulesets (PUT the full ruleset; required_status_checks is nested under rules):
gh api "repos/$REPO/rulesets/$ID" > /tmp/rs.json    # back up first
# edit the .rules[] required_status_checks[].context entries, then:
gh api -X PUT "repos/$REPO/rulesets/$ID" --input /tmp/rs.json

# Classic branch protection: this endpoint REPLACES the entire contexts list,
# so you must send ALL required contexts (renamed + unchanged), or you silently
# drop the others. Read the current list, swap the renamed entries, send it back.
gh api "repos/$REPO/branches/main/protection/required_status_checks" \
  --jq '{strict: .strict, contexts: .contexts}' \
  | jq '.contexts |= map(sub("\\^14\\.0"; "^14.3"))' > /tmp/rsc.json
gh api -X PATCH "repos/$REPO/branches/main/protection/required_status_checks" --input /tmp/rsc.json
```

Verify the contexts match the jobs the workflow now emits. The context string is the **check-run name** from `repos/$REPO/commits/$SHA/check-runs[].name`, which for reusable-/multi-job workflows includes the `workflow / job (matrix)` prefix (e.g. `ci / PHPStan (8.2, ^14.3)`) — not the bare job name. (This is the same source `init-branch-protection.sh` uses; the `/actions/runs/{id}/jobs` endpoint returns the bare job name and is wrong for context matching.)

### Required "SonarCloud Code Analysis" status absent — AutoScan never analyzed the PR

The same "BLOCKED with every visible check green" symptom also occurs with a *correct* required-checks list when the context comes from an external app that never ran. SonarCloud AutoScan sometimes never analyzes a PR: its `sonarqubecloud` check-suite sits `queued` with zero check runs, so the required `SonarCloud Code Analysis` context never reports (and, as above, a missing context does not appear in `gh pr checks`). Diagnose:

```bash
# The sonarqubecloud check-suite is queued with no runs
gh api "repos/$REPO/commits/$SHA/check-suites" \
  --jq '.check_suites[] | {app: .app.slug, status, runs: .latest_check_runs_count}'
# → {"app":"sonarqubecloud","status":"queued","runs":0}

# The project's last analysis on sonarcloud.io predates the PR
curl -s "https://sonarcloud.io/api/components/show?component=$SONAR_PROJECT_KEY" \
  | jq -r '.component.analysisDate'
```

**Fix:** push a new head to the PR branch — an empty commit suffices; the push re-fires the webhook and analysis completes:

```bash
git commit -S --signoff --allow-empty -m "chore: retrigger CI"
git push
```

### Merge queue silently fails to enqueue a green PR

On a repo with a `merge_queue` ruleset rule, an all-green PR with auto-merge armed (`mergeStateStatus: CLEAN`) sometimes never enters the queue — no queue entry, no `merge_group` build, it just sits OPEN. Confirm it is genuinely stuck before acting:

```bash
gh api graphql -f query='query($owner:String!,$repo:String!,$branch:String!){
  repository(owner:$owner,name:$repo){
    mergeQueue(branch:$branch){entries(first:10){nodes{pullRequest{number} state position}}}
  }
}' -f owner=OWNER -f repo=REPO -f branch=main \
  --jq '.data.repository.mergeQueue?.entries?.nodes[]? // empty'
gh run list --repo OWNER/REPO --event merge_group -L 5   # any build for this PR?
```

If there is no entry and no `merge_group` run after the required checks have passed, admin-merge with the queue's configured method (preserves signatures with `--merge`):

```bash
gh pr merge <PR> --repo OWNER/REPO --merge --admin
```

> **Scope of this escape hatch:** only in repos whose governance is ours, only for this stuck-queue failure mode, and only with the operator's explicit go for that PR. `--admin` bypasses required reviews and status checks wholesale — on upstream/community repos (or to merge your own unreviewed PR anywhere) it is never appropriate, no matter how trivial the fix or how red the main branch. Holding admin permission is a trust grant, not a merge mandate.

### Arming a merge queue PR: `--auto` with no strategy flag

On a `merge_queue` repo the **queue owns the merge method**, so passing an
explicit strategy to `gh pr merge` prints a warning (the command still
succeeds and enqueues the PR):

```bash
gh pr merge <PR> --repo OWNER/REPO --merge --auto
# gh output: ! The merge strategy for main is set by the merge queue
```

To avoid the confusing warning, arm it with a bare `--auto` (no
`--merge`/`--squash`/`--rebase`); the queue applies its configured method when
the PR reaches the front:

```bash
gh pr merge <PR> --repo OWNER/REPO --auto     # enqueues when the gate passes
```

(The explicit-strategy form is still correct for `--admin` bypass merges, which
run outside the queue — as in the enqueue-failure fallback above.)

### Batch review-fix commits before pushing — each push re-runs the full PR CI

Merge queue repos typically re-run the **entire** required matrix (functional
across every PHP × TYPO3 combo, e2e, etc.) on every push to the PR head (the
standard PR status checks; the queue's own CI runs later on the merge group),
which can be ~8+ minutes. Fixing reviewer nitpicks one-commit-one-push then
turns into many full-matrix cycles for trivial edits.

Collect **all** outstanding review fixes across every open thread, apply them
locally, run the relevant suites once, and push a **single** commit. Only then
reply to and resolve the threads. This costs one CI cycle instead of N, and avoids
racing a half-fixed head into the queue.

## References

- [GitHub Branch Protection](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches)
- [Signing Commits](https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-commits)
- [About Merge Methods](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/about-merge-methods-on-github)
