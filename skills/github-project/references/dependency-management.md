# Dependency Management Reference

Dependabot and Renovate configuration patterns, auto-merge workflows, and troubleshooting.

## Dependabot

### Ecosystem Hygiene — Only Declare What the Repo Actually Has

Dependabot's update job runs on the ecosystems configured, whether or not the manifest files exist. Some ecosystems **hard-fail** when their manifest is missing; others silently no-op. Declaring ecosystems that don't apply turns main red on every scheduled Dependabot run, for no benefit:

| Ecosystem | Missing manifest behavior |
|-----------|---------------------------|
| `npm` | **Hard error** — `dependency_file_not_found: /package.json not found` |
| `devcontainers` | **Hard error** — `no devcontainers configs found` |
| `docker` | Silent no-op (scans Dockerfile only if present) |
| `gomod` | Silent no-op (scans go.mod only if present) |
| `github-actions` | Silent no-op (scans workflows only if present) |
| `pip` | **Hard error** — fails if no requirements*.txt / pyproject.toml |
| `composer` | **Hard error** — fails if no composer.json |

**Rule:** match the template's ecosystem set to the **class** of repo. A `go-lib` template shouldn't ship with `npm` and `devcontainers` entries because libraries don't have `package.json` or `.devcontainer/`. A `go-app` template can reasonably include `npm` because some Go apps ship frontend assets — but the first consumer without frontend assets will fail weekly until someone removes the entry or adds the manifest.

**Diagnosing a weekly Dependabot failure on main:**

```bash
# Latest Dependabot run conclusions
gh api "repos/OWNER/REPO/actions/runs?per_page=10" --jq '
  [.workflow_runs[] | select(.name == "Dependabot Updates" or .name == "Dependabot")
    | {conclusion, created_at, html_url}]'

# Open the failing run's log to find the specific ecosystem:
gh run view <RUN_ID> --repo OWNER/REPO --log-failed |
  grep -iE "dependency_file_not_found|no .* configs found" | head -5
```

If the failure comes from a template-derived ecosystem that doesn't apply: fix the template (so new consumers inherit the fix) *and* open a consumer-side PR to drop the ecosystem (so the existing repo stops failing). Running only one half leaves the drift check failing on the PR or the schedule failing on main. See [multi-repo-operations.md](./multi-repo-operations.md) for the template-consumer coordination pattern.

### Maintained Release Branches — `target-branch`

Dependabot scans **only the default branch** by default. A repo that keeps long-lived release branches (e.g. `13.4`, `12.4` alongside `main`) receives action/dependency bumps on the default branch only; the release branches silently fall behind and their pinned actions go stale — a divergence nobody notices until, say, a backport PR renders with an old pinned action while `main` already moved on.

Add one update block **per maintained branch** with `target-branch`:

```yaml
version: 2
updates:
  # Default branch
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: weekly

  # Maintained release branches — Dependabot only scans the default branch
  # otherwise, so these bump the branch in place (no backport needed).
  - package-ecosystem: "github-actions"
    directory: "/"
    target-branch: "13.4"
    schedule:
      interval: weekly

  - package-ecosystem: "github-actions"
    directory: "/"
    target-branch: "12.4"
    schedule:
      interval: weekly
```

Notes:

- `target-branch` PRs open **against that branch**, not the default — no backport labels or cherry-picks involved.
- List only branches that actually exist and are maintained; a `target-branch` pointing at a missing branch makes that update run **fail** (visible in the repo's Dependabot update logs — see "Diagnosing a weekly Dependabot failure" above), it does not silently no-op.
- The alternative — labeling default-branch bump PRs for backport — works but reintroduces per-PR conflict resolution once branch workflows have drifted; `target-branch` bumps in place instead.
- `groups`, `cooldown`, `commit-message`, and `open-pull-requests-limit` apply per block.

### Grouping Dependencies
```yaml
updates:
  - package-ecosystem: "gomod"
    directory: "/"
    schedule:
      interval: "weekly"
    groups:
      all-dependencies:
        patterns:
          - "*"

      # Or group by type
      production:
        dependency-type: "production"
      development:
        dependency-type: "development"
```

### SHA-Pinned Actions — Comment Maintenance and Deprecation Warnings

**Dependabot maintains the version comment, not just the SHA.** With the `github-actions` ecosystem enabled, a bump rewrites both the pinned SHA **and** the trailing `# vX.Y.Z` comment in one diff:

```diff
- uses: actions/cache@cdf6c1fa76f9f475f3d7449005a359c84ca0f306 # v5.0.3
+ uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
```

So annotating bare SHA pins once (with **API-verified** tags — resolve each SHA via `gh api repos/OWNER/ACTION/tags`) puts them in the exact format Dependabot then keeps current. Without the `github-actions` ecosystem declared, action pins are only ever updated by hand and silently drift.

**A runtime-deprecation warning is not cleared by a version bump unless the newer release changed the runtime.** Before claiming "bumping action X fixes the Node NN deprecation", check the target version's `action.yml`:

```bash
gh api -H "Accept: application/vnd.github.raw" \
  repos/OWNER/ACTION/contents/action.yml?ref=<tag> | grep -A1 '^runs:'
# runs.using: 'node20'  → still deprecated; the bump does NOT clear the warning
```

An action already pinned at its latest release can still emit the warning if upstream ships no newer-runtime build — the fix is then an upstream change or a replacement action, not a bump. Don't assert the warning is fixed off the version number alone.

### Bulk SHA resolution — verify the SHA maps *back* to the tag

Resolving tag → SHA for a set of actions is a loop, and a loop that prints
`action@<40-hex> # vX.Y.Z` looks authoritative whether or not it is right. Two
failure modes survive a confident-looking run, and neither is caught by
`actionlint` or by CI — a wrong-but-valid SHA pins silently:

**1. A SHA that belongs to no tag.** Verify the reverse direction — SHA → tag —
against the API, not against your own resolution step:

```bash
# For each pin, ask the tags API which tag(s) point at this SHA. Empty = fabricated or stale.
gh api "repos/$REPO/tags?per_page=100" --jq ".[] | select(.commit.sha==\"$SHA\") | .name"
```

In one run this caught a pin for `juliangruber/read-file-action` whose SHA mapped
to **no tag at all** — six of seven resolved correctly, which is exactly why the
seventh was easy to miss.

**2. A regex that mis-ranks tags.** Picking "latest" by pattern-matching tag names
breaks on any project not using three-part semver. A `^v?[0-9]+\.[0-9]+\.[0-9]+$`
filter silently skips two-part tags, so `github/issue-labeler` — whose releases are
`v3.4`, `v3.3`, `v3.2` — resolved to "latest `v2.4.1`", i.e. a **downgrade
disguised as an upgrade**.

Ask GitHub for latest instead of deriving it:

```bash
gh api "repos/$REPO/releases/latest" --jq .tag_name   # authoritative
```

Note the endpoint 404s for repos that tag without publishing releases — fall back
to the tags list *and reason about the versioning scheme*, rather than assuming a
shape.

**A downgrade is the tell.** If a "latest" lookup ever resolves *below* what the
repo already pins, the lookup is wrong until proven otherwise — that direction is
almost never a real upgrade.

### Dependency PRs must trigger the test job

A `paths:` filter listing source globs only does **not** match the manifest, so
every dependency PR — including Dependabot's and Renovate's — **skips the test job
and merges untested**. The PR looks green because the tests never ran.

```yaml
# Before: a go.mod-only change matches nothing here, so no tests run
on:
  pull_request:
    paths:
      - '**.go'
```

Include the manifest, its lockfile, any toolchain pin, and the workflow itself:

```yaml
on:
  pull_request:
    paths:
      - '**.go'
      - 'go.mod'
      - 'go.sum'
      - '.go-version'
      - '.github/workflows/unit_tests.yaml'
```

Same shape in every ecosystem: `package.json`/`package-lock.json`, `composer.json`/`composer.lock`, `pyproject.toml`/`uv.lock`.

**Verify by observation, not by reading the YAML** — check that the test job
actually appears on a manifest-only PR:

```bash
gh pr view "$PR" --repo "$R" --json statusCheckRollup \
  --jq '[.statusCheckRollup[]?.name] | index("unit_tests") // "TEST JOB DID NOT RUN"'
```

**Real case:** a Go provider whose `unit_tests` filter was `'**.go'`. Its
dependency upgrade PR ran only `triage` and `DCO`; adding the manifest paths made
`unit_tests` appear on the same PR and pass. Every prior dependency bump in that
repo had merged without a single test running.

## Renovate

### Auto-merge Configuration (Recommended)

**IMPORTANT:** Use `platformAutomerge: true` to leverage Renovate's bypass permissions:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:recommended"],
  "automergeType": "pr",
  "platformAutomerge": true,
  "packageRules": [
    {
      "matchUpdateTypes": ["patch", "minor", "pin", "digest"],
      "automerge": true
    }
  ]
}
```

| Setting | Value | Purpose |
|---------|-------|---------|
| `automergeType` | `"pr"` | Merge via PR (not branch) for visibility |
| `platformAutomerge` | `true` | Use GitHub's auto-merge (Renovate enables it) |
| `automerge` | `true` | Enable auto-merge for matching packages |

### GitHub Actions digest pinning — exempt org-owned resources (last-match-wins)

Renovate applies the **last matching `packageRule`**, so rule order decides pinning. If a repo opts into `helpers:pinGitHubActionDigests` (which SHA-pins *all* actions), an exemption for org-owned resources placed only in a *shared* preset is overridden by the later opt-in preset — and Renovate SHA-pins your own reusable workflows (`org/.github/...@main` → `@<sha>`), which are meant to track a branch so fixes reach every consumer without a per-repo digest bump.

Put the exemption where it wins:

- **Repo-level** — in the repo's own `packageRules` (evaluated after all `extends`):

  ```json
  {
    "matchManagers": ["github-actions"],
    "matchPackageNames": ["myorg/**"],
    "pinDigests": false
  }
  ```

- **Better, org-wide** — a bundled sub-preset that extends the pin preset and applies the exemption *after* it, so consumers just `extends: ["github>myorg/renovate-config:pinning"]` and cannot omit or mis-order it:

  ```json
  {
    "extends": ["github>myorg/renovate-config", "helpers:pinGitHubActionDigests"],
    "packageRules": [
      { "matchManagers": ["github-actions"], "matchPackageNames": ["myorg/**"], "pinDigests": false }
    ]
  }
  ```

A shared-preset exemption alone gives false confidence: it is silently overridden the moment a repo extends the pin preset after it. This surfaced when Renovate auto-merged a PR that SHA-pinned an `org/.github` reusable workflow against the org's stated policy.

## Auto-merge Workflow

### Auto-merge Decision Matrix

| Repository Configuration | Workflow Pattern | Key Difference |
|--------------------------|------------------|----------------|
| Merge queue enabled | GraphQL `enqueuePullRequest` | Adds PR to queue, queue handles merge |
| Branch protection (no queue) | `gh pr merge --auto` | Enables auto-merge, GitHub merges when checks pass |
| No branch protection | `gh pr merge --rebase` | Direct merge, no waiting |

### Renovate vs Dependabot Auto-merge

| Capability | Renovate | Dependabot |
|------------|----------|------------|
| Native auto-merge | ✅ `platformAutomerge` | ❌ Needs workflow |
| Bypass permissions | ✅ When in bypass list | ❌ Via `GITHUB_TOKEN` only |
| Lock file maintenance | ✅ Built-in | ❌ Manual |
| Who enables auto-merge | `app/renovate` | `app/github-actions` |

**Critical difference:** When Renovate enables auto-merge via `platformAutomerge`, it appears as `enabledBy: app/renovate` and can use bypass permissions. When a workflow enables auto-merge, it appears as `enabledBy: app/github-actions` which may NOT have bypass permissions.

### GitHub Actions Auto-merge (Dependabot Only)

For Renovate PRs, let Renovate handle auto-merge via `platformAutomerge`. Only use workflows for Dependabot:

```yaml
# .github/workflows/auto-merge-deps.yml
# For Renovate: Only approve (Renovate handles auto-merge via platformAutomerge)
# For Dependabot: Approve and enable auto-merge
name: Auto-merge dependency PRs

on:
  pull_request_target:
    types: [opened, synchronize, reopened]

permissions: {}

jobs:
  auto-merge:
    runs-on: ubuntu-latest
    if: github.event.pull_request.user.login == 'dependabot[bot]' || github.event.pull_request.user.login == 'renovate[bot]'
    permissions:
      contents: write
      pull-requests: write

    steps:
      - name: Harden Runner
        uses: step-security/harden-runner@v2
        with:
          egress-policy: audit

      - name: Dependabot metadata
        id: metadata
        if: github.event.pull_request.user.login == 'dependabot[bot]'
        uses: dependabot/fetch-metadata@v2
        with:
          github-token: "${{ secrets.GITHUB_TOKEN }}"

      - name: Auto-approve PR
        run: gh pr review --approve "$PR_URL"
        env:
          PR_URL: ${{ github.event.pull_request.html_url }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      # Only enable auto-merge for Dependabot PRs
      # Renovate handles its own auto-merge via platformAutomerge
      - name: Enable auto-merge (Dependabot only)
        if: github.event.pull_request.user.login == 'dependabot[bot]'
        run: gh pr merge --auto --merge "$PR_URL"
        env:
          PR_URL: ${{ github.event.pull_request.html_url }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### GitHub Actions Auto-merge (Merge Queue)
```yaml
# .github/workflows/auto-merge-deps.yml
# Use when: Repository has merge queue enabled
# IMPORTANT: mergeMethod is NOT a valid argument for enqueuePullRequest
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
    # Use github.event.pull_request.user.login (not github.actor)
    # because actor can change on synchronize/rerun events
    if: >-
      github.event.pull_request.user.login == 'dependabot[bot]' ||
      github.event.pull_request.user.login == 'renovate[bot]'
    steps:
      - name: Auto-approve PR
        run: gh pr review --approve "$PR_URL"
        env:
          PR_URL: ${{ github.event.pull_request.html_url }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Add to merge queue
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          PR_NODE_ID: ${{ github.event.pull_request.node_id }}
        run: |
          gh api graphql -f query='
            mutation($pullRequestId: ID!) {
              enqueuePullRequest(input: {pullRequestId: $pullRequestId}) {
                mergeQueueEntry { id }
              }
            }' -f pullRequestId="$PR_NODE_ID"
```

## Branch Protection Configuration

### Required Status Checks - CRITICAL

**Check names MUST match exactly.** Matrix jobs produce names with suffixes:

| Workflow Definition | Actual Check Name |
|---------------------|-------------------|
| `job-name:` | `job-name` |
| `name: job (${{ matrix.variant }})` | `job (variant-value)` |

**Example:** If workflow has:
```yaml
jobs:
  smoke-test:
    strategy:
      matrix:
        variant: [minimal, full]
    name: smoke-test (${{ matrix.name }})
```

Branch protection must list:
- `smoke-test (minimal)`
- `smoke-test (full)`

NOT just `smoke-test`.

### Bypass Permissions for Auto-merge

Add Renovate and Dependabot to bypass list:

```bash
gh api repos/OWNER/REPO/branches/main/protection/required_pull_request_reviews -X PATCH \
  --input - << 'EOF'
{
  "dismiss_stale_reviews": false,
  "require_code_owner_reviews": false,
  "required_approving_review_count": 1,
  "bypass_pull_request_allowances": {
    "apps": ["dependabot", "renovate"]
  }
}
EOF
```

### Code Owner Reviews - AVOID with Auto-merge

**Problem:** `require_code_owner_reviews: true` blocks auto-merge even when the bot is in the bypass list.

| Setting | Effect on Auto-merge |
|---------|---------------------|
| `require_code_owner_reviews: false` | ✅ Works - any approval counts |
| `require_code_owner_reviews: true` | ❌ Blocked - `github-actions` approval doesn't satisfy code owner requirement |

**Why:** Bypass permissions only apply at merge time, but GitHub's `mergeStateStatus` shows `BLOCKED` before that, preventing auto-merge from being attempted.

**Solution:** Disable `require_code_owner_reviews` for repos with dependency auto-merge:

```bash
gh api repos/OWNER/REPO/branches/main/protection/required_pull_request_reviews -X PATCH \
  -f require_code_owner_reviews=false
```

### Merge Strategy Requirements

| Branch Protection Setting | Allowed Merge Methods |
|---------------------------|----------------------|
| `required_linear_history: true` | Rebase only (`--rebase`) |
| `required_linear_history: false` | Merge, squash, or rebase |

If you see "Merge method X is not allowed", check:
```bash
gh api repos/OWNER/REPO/branches/main/protection --jq '.required_linear_history'
```

### Strict Status Checks

With `strict: true`, PRs must be up-to-date with main before merging:

```bash
# Check if strict is enabled
gh api repos/OWNER/REPO/branches/main/protection/required_status_checks --jq '.strict'
```

**Impact:** After one PR merges, others become "behind" and need rebasing. Renovate handles this automatically via `@renovate rebase` or its scheduling.

## Troubleshooting Auto-merge

### PR Shows BLOCKED Despite Passing Checks

1. **Check names mismatch:**
   ```bash
   # Get actual check names from PR
   gh api graphql -f query='query($owner:String!,$repo:String!,$pr:Int!){
     repository(owner:$owner,name:$repo){
       pullRequest(number:$pr){
         commits(last:1){nodes{commit{statusCheckRollup{contexts(first:50){
           nodes{...on CheckRun{name conclusion}}
         }}}}}
       }
     }
   }' -f owner=OWNER -f repo=REPO -F pr=NUMBER --jq '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[].name'

   # Compare with required checks
   gh api repos/OWNER/REPO/branches/main/protection/required_status_checks --jq '.checks[].context'
   ```

2. **Code owner reviews required:**
   ```bash
   gh api repos/OWNER/REPO/branches/main/protection/required_pull_request_reviews --jq '.require_code_owner_reviews'
   ```

3. **Branch behind main:**
   ```bash
   gh api graphql -f query='query{repository(owner:"OWNER",name:"REPO"){
     pullRequest(number:PR){mergeStateStatus}
   }}' --jq '.data.repository.pullRequest.mergeStateStatus'
   # BEHIND = needs rebase
   ```

### Workflow Not Triggering

**Problem:** Multiple PRs merged rapidly may skip push events for subsequent commits.

**Solution:** Add `workflow_dispatch` for manual triggering:
```yaml
on:
  push:
    branches: [main]
  workflow_dispatch:  # Allow manual trigger
```

Then trigger manually:
```bash
gh workflow run build.yml --repo OWNER/REPO --ref main
```

### CI Cannot Push to Protected Branch

**Error:** `GH006: Protected branch update failed - Changes must be made through a pull request`

**Cause:** Workflow tries to push directly to main (e.g., lock file updates).

**Solution:** Use Renovate's `lockFileMaintenance` instead of CI pushing directly:
```json
{
  "lockFileMaintenance": {
    "enabled": true,
    "schedule": ["before 6am on monday"]
  }
}
```

### Auto-merge Enabled by Wrong Actor

**Problem:** Auto-merge shows `enabledBy: github-actions` instead of `enabledBy: renovate`.

**Impact:** `github-actions` may not have bypass permissions.

**Solution:** For Renovate PRs, don't enable auto-merge in workflows. Let Renovate handle it via `platformAutomerge: true`.

### Merge Method Mismatch in Auto-merge Workflow

**Error:** `Merge method 'rebase' is not allowed on this repository` (or squash/merge)

**Cause:** The auto-merge workflow uses `--rebase` but the repository only allows merge commits (or vice versa).

**Diagnosis:**
```bash
# Check which merge methods are allowed
gh api repos/OWNER/REPO --jq '{merge: .allow_merge_commit, squash: .allow_squash_merge, rebase: .allow_rebase_merge}'
```

**Solution:** Update the workflow's merge command to match:
```yaml
# Use the method that matches repo settings:
run: gh pr merge --auto --merge "$PR_URL"   # if allow_merge_commit: true
run: gh pr merge --auto --squash "$PR_URL"  # if allow_squash_merge: true
run: gh pr merge --auto --rebase "$PR_URL"  # if allow_rebase_merge: true
```

### `github.actor` Unreliable for Bot Detection

**Problem:** Auto-merge workflow uses `github.actor == 'dependabot[bot]'` but the workflow doesn't trigger on `synchronize` or `rerun` events.

**Cause:** `github.actor` reflects who triggered the event, not who opened the PR. On `synchronize` events (new push) or manual reruns, the actor may change to the person who triggered the rerun.

**Solution:** Always use `github.event.pull_request.user.login` instead:
```yaml
# ❌ Wrong - actor changes on synchronize/rerun
if: github.actor == 'dependabot[bot]'

# ✅ Correct - user.login is stable for the PR author
if: github.event.pull_request.user.login == 'dependabot[bot]'
```

### The gitleaks Action Fails on Dependabot/Renovate PRs

**Error:** `gitleaks-action@v2` fails with a license error on bot PRs.

**Cause:** `gitleaks-action@v2` requires a `GITLEAKS_LICENSE` secret for organization repositories, and Dependabot runs with restricted secret access — it can only read secrets prefixed with `DEPENDABOT_`. So the scan cannot be licensed on exactly the PRs that need it.

**Solution:** Call the org reusable, which runs betterleaks. (This is the third-party scan in your workflow, not GitHub's own secret scanning, which is configured per repository and unaffected.) It is OSS, needs no license, and therefore has no bot-PR failure mode — no secret is passed to it at all:
```yaml
jobs:
  gitleaks:
    uses: netresearch/.github/.github/workflows/gitleaks.yml@main
```

Do not skip the scan for bot PRs: a dependency update can carry a secret like any other change. For known false positives, add a `.gitleaks.toml` allowlist — the repo's own file is honoured, so tune it there rather than disabling the job.

### Pre-existing PRs Don't Auto-merge

**Problem:** PRs opened before the auto-merge workflow was added don't get auto-merged.

**Cause:** The workflow triggers on `opened`, `synchronize`, and `reopened`. Pre-existing PRs already had their `opened` event.

**Solution:** Either:
1. Comment `@dependabot rebase` or `@renovate rebase` to trigger a `synchronize` event
2. Close and reopen the PR to trigger `reopened`
3. Manually merge the pre-existing PRs

### GITHUB_TOKEN Cannot Modify Workflow Files

**Problem:** Auto-merge fails for PRs that update `.github/workflows/` files.

**Cause:** `GITHUB_TOKEN` (OAuth `gho_*` tokens) lack the `workflows` scope and cannot push or merge changes to workflow files. This is a GitHub security restriction.

**Solution:** The `auto-merge-direct.yml` template includes a check for workflow file changes and skips auto-merge for those PRs, leaving a comment instead:
```yaml
- name: Check for workflow file changes
  run: |
    WORKFLOW_FILES=$(gh pr diff "$PR_URL" --name-only | grep -E '^\\.github/workflows/' || true)
    if [ -n "$WORKFLOW_FILES" ]; then
      echo "modifies_workflows=true" >> "$GITHUB_OUTPUT"
    fi

- name: Merge PR
  if: steps.check-workflows.outputs.modifies_workflows != 'true'
  run: gh pr merge --rebase "$PR_URL"
```

PRs modifying workflow files require manual merge by a repository admin.

### Nameless `package.json` Pollutes the Lockfile With the Worktree Dir Name

**Problem:** Working on a Dependabot/Renovate npm PR in a git worktree (e.g. `fix-dependabot-npm-uuid/`) and running `npm install` produces a spurious `package-lock.json` change — the root package `"name"` flips to the worktree directory name — that a reviewer or CI flags as an unrelated diff.

**Cause:** When `package.json` has **no `name` field**, npm falls back to stamping the **checkout directory name** into `package-lock.json` as the root package name. In the git worktree convention, the checkout dir is *branch-named* (e.g. `fix-dependabot-npm-uuid`) rather than the repo name, so every `npm install` rewrites the lockfile's `name` to whatever branch folder you happen to be in.

```jsonc
// package-lock.json after `npm install` in a worktree named fix-dependabot-npm-uuid/
{
  "name": "fix-dependabot-npm-uuid",   // ← polluted: was absent / repo name before
  "lockfileVersion": 3,
  ...
}
```

**Solution:** Add an explicit `name` field to `package.json` so npm stops deriving it from the directory:
```jsonc
// package.json
{
  "name": "my-repo",
  "version": "1.0.0",
  ...
}
```

The lockfile `name` then stays stable regardless of which worktree folder you run `npm install` in. This bites specifically in git worktree workflows; a plain clone (dir == repo name) masks it.

## Enforcing Signed Commits + DCO Without Blocking the Bots

Requiring **signed commits** (`required_signatures`) and/or **DCO sign-off** across repos collides head-on with dependency automation, because bot commits are typically **unsigned** and carry **no `Signed-off-by`**:

- `required_signatures` has **no bot exemption** — it applies to every commit. Renovate commits pushed over git are unverified; Dependabot commits are *inconsistently* signed (some `verification.verified=true`, some `unsigned` in the same org). So turning it on blocks those PRs.
- DCO requires a `Signed-off-by` trailer bots don't add — a naive DCO gate blocks **every** Dependabot/Renovate PR.

Verify the blast radius before flipping anything on:

```bash
# Are bot commits signed?
gh api "repos/OWNER/REPO/commits?per_page=40" \
  --jq '[.[]|select(.commit.author.name|test("dependabot|renovate";"i"))][0]
        | {verified:.commit.verification.verified, signoff:(.commit.message|test("Signed-off-by"))}'
```

**A working recipe (per repo — GitHub Free has no org-level rulesets, so there is no org-wide shortcut):**

1. **Make Renovate sign.** Set `platformCommit: enabled` in the shared Renovate preset (or repo config). Renovate then creates commits through the GitHub API, which GitHub signs → `verified`.
2. **Drop Dependabot** where signatures are required — it can't be made to sign reliably. Standardise on Renovate (which now signs). This also ends the double-manager problem if both were configured.
3. **Exempt bots from DCO**, not from signatures. A reusable DCO check with a bot-login allowlist (`dependabot[bot],renovate[bot],github-actions[bot]`) lets bot PRs pass while still requiring humans to `git commit -s`. (Bots stay unsigned-off but are allowlisted; they are *signed* via step 1.)
4. **Enforce.** `required_signatures` via classic protection `POST repos/OWNER/REPO/branches/main/protection/required_signatures`, or — on repos with **no classic protection** (rulesets only) — a ruleset rule `{"type":"required_signatures"}`. Add the DCO check as a required context the same way (classic `required_status_checks` or a `required_status_checks` ruleset rule).

Note the classic `PATCH …/required_status_checks` **404s** ("Required status checks not enabled") when that component isn't already configured — add the check via a ruleset instead, which works regardless of classic protection.
## Cross-repo release race: dependent PR CI resolves composer too early

When repo B depends on a version of repo A that was *just* released, the order is: merge the upstream PR → tag → **wait for A's release workflow AND the package registry (Packagist) to publish** → only then act on the dependent PR in B (push commits to its branch, or flip it from draft to ready). Doing either earlier gives a CI run whose composer/npm resolve step reads stale registry metadata — every dependency-installing job fails at once. That failure pattern (all jobs red at the install step, right after an upstream release) is pure timing: re-run the checks, don't debug the PR.

## Dependabot alert dismissal: 280-character comment cap

`gh api -X PATCH repos/OWNER/REPO/dependabot/alerts/N` rejects a `dismissed_comment` over 280 characters with HTTP 422 (`Only 280 characters are allowed`) — check `${#COMMENT}` before the call. Valid `dismissed_reason` values: `fix_started`, `inaccurate`, `no_bandwidth`, `not_used`, `tolerable_risk` (use `not_used` for "vulnerable code not in execution path").

## Merging the workflow-file bot PRs that auto-merge skipped

The "GITHUB_TOKEN Cannot Modify Workflow Files" section above explains why auto-merge skips these PRs. To land them by hand: clone and merge locally — SSH (`git clone git@github.com:…`) is the reliable path in environments without a working credential helper (HTTPS works only when credentials are explicitly available). For repos with several workflow PRs, merge them one at a time — they typically touch the same files.

## Updating GitHub Actions versions: fetch the latest from the API, never guess

```bash
gh api 'repos/OWNER/REPO/tags?per_page=1' --jq '.[0] | "\(.name) \(.commit.sha)"'
```

Verify the SHA is valid AND that it is the latest version (a valid SHA of an old tag passes review while staying outdated), then update ALL occurrences across `.github/workflows/*.yml`, not just the failing one.

## `composer audit` flags a transitive CVE nothing can bump — mirror the audit-ignore

A transitive package can be pinned below its fixed version by a direct dependency you don't control (e.g. `firebase/php-jwt < 7` held back by an OAuth lib's constraint, which is itself pinned by a wrapper library). No `composer update` in the app repo can fix that. The default branch usually already tolerates the CVE via `config.audit.ignore` in `composer.json` — mirror the identical entry onto the diverging branch: JSON-only, lock untouched, no behavior change. Verify with the exact CI command (`composer audit --locked …` → exit 0, advisory listed as "ignored"). The real fix — releasing the pinning library with a loosened constraint — is a separate effort; don't block the immediate green on it.

## `pnpm/action-setup` must run BEFORE `actions/setup-node` with `cache: "pnpm"`

`actions/setup-node` with pnpm caching resolves the pnpm executable at setup time — if `pnpm/action-setup` hasn't run yet, it fails with `Unable to locate executable: pnpm`. Order the steps pnpm-first in any workflow using both.
