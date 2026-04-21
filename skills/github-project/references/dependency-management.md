# Dependency Management Reference

Dependabot and Renovate configuration patterns, auto-merge workflows, and troubleshooting.

## Dependabot

### Basic Configuration
```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: "gomod"
    directory: "/"
    schedule:
      interval: "weekly"
      day: "monday"
      time: "06:00"
      timezone: "Europe/Berlin"
```

### Package Ecosystems

| Ecosystem | Languages/Tools |
|-----------|-----------------|
| gomod | Go modules |
| npm | JavaScript/Node.js |
| composer | PHP |
| pip | Python |
| cargo | Rust |
| maven | Java |
| gradle | Java/Kotlin |
| nuget | .NET |
| bundler | Ruby |
| docker | Dockerfiles |
| github-actions | GitHub Actions |
| terraform | Terraform |

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

### Commit Message Prefixes
```yaml
updates:
  - package-ecosystem: "gomod"
    directory: "/"
    schedule:
      interval: "weekly"
    commit-message:
      prefix: "deps"
      prefix-development: "deps(dev)"
      include: "scope"
    labels:
      - "dependencies"
```

### Multiple Ecosystems
```yaml
version: 2
updates:
  - package-ecosystem: "gomod"
    directory: "/"
    schedule:
      interval: "weekly"
    groups:
      dependencies:
        patterns:
          - "*"
    commit-message:
      prefix: "deps"
    labels:
      - "dependencies"

  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    groups:
      github-actions:
        patterns:
          - "*"
    commit-message:
      prefix: "ci"
    labels:
      - "dependencies"
      - "github-actions"

  - package-ecosystem: "docker"
    directory: "/"
    schedule:
      interval: "weekly"
    commit-message:
      prefix: "docker"
    labels:
      - "dependencies"
      - "docker"
```

### Ignoring Dependencies
```yaml
updates:
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
    ignore:
      - dependency-name: "lodash"
        versions: [">=5.0.0"]
      - dependency-name: "react"
        update-types: ["version-update:semver-major"]
```

### Reviewers and Assignees
```yaml
updates:
  - package-ecosystem: "gomod"
    directory: "/"
    schedule:
      interval: "weekly"
    reviewers:
      - "username"
      - "org/team-name"
    assignees:
      - "username"
```

## Renovate

### Basic Configuration
```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:recommended"
  ]
}
```

### Extended Configuration
```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": [
    "config:recommended",
    ":semanticCommits",
    ":semanticCommitTypeAll(chore)",
    "group:allNonMajor"
  ],
  "labels": ["dependencies"],
  "prHourlyLimit": 2,
  "prConcurrentLimit": 5,
  "timezone": "Europe/Berlin",
  "schedule": ["before 7am on monday"]
}
```

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

### Lock File Maintenance

Use Renovate for lock file updates instead of CI workflows that push directly to main:

```json
{
  "lockFileMaintenance": {
    "enabled": true,
    "schedule": ["before 6am on monday"]
  }
}
```

**Why:** CI workflows cannot push to protected branches. Renovate creates PRs that go through normal review/merge process.

### Grouping Rules
```json
{
  "extends": ["config:recommended"],
  "packageRules": [
    {
      "matchPackagePatterns": ["^@types/"],
      "groupName": "TypeScript types"
    },
    {
      "matchPackagePatterns": ["eslint"],
      "groupName": "ESLint"
    },
    {
      "matchPackagePatterns": ["^react"],
      "groupName": "React"
    }
  ]
}
```

### Security Updates
```json
{
  "extends": [
    "config:recommended",
    ":enableVulnerabilityAlerts"
  ],
  "vulnerabilityAlerts": {
    "labels": ["security"],
    "automerge": true
  }
}
```

### PHP/Composer Configuration
```json
{
  "extends": ["config:recommended"],
  "composer": {
    "enabled": true
  },
  "packageRules": [
    {
      "matchPackagePatterns": ["^typo3/"],
      "groupName": "TYPO3"
    },
    {
      "matchPackagePatterns": ["^phpstan/", "^phpunit/"],
      "groupName": "PHP dev tools"
    }
  ]
}
```

### Go Configuration
```json
{
  "extends": ["config:recommended"],
  "gomod": {
    "enabled": true
  },
  "packageRules": [
    {
      "matchManagers": ["gomod"],
      "matchUpdateTypes": ["minor", "patch"],
      "automerge": true
    }
  ]
}
```

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

### Gitleaks Fails on Dependabot/Renovate PRs

**Error:** `gitleaks-action` fails with license error on bot PRs.

**Cause:** `gitleaks-action@v2` requires a `GITLEAKS_LICENSE` secret, but Dependabot runs with restricted secret access — it can only access secrets prefixed with `DEPENDABOT_`.

**Solution:** Skip gitleaks on bot PRs or use the free mode:
```yaml
- name: Gitleaks
  uses: gitleaks/gitleaks-action@v2
  # Skip on bot PRs where GITLEAKS_LICENSE is unavailable
  if: github.event.pull_request.user.login != 'dependabot[bot]' && github.event.pull_request.user.login != 'renovate[bot]'
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    GITLEAKS_LICENSE: ${{ secrets.GITLEAKS_LICENSE }}
```

Or add a `.gitleaks.toml` allowlist for known false positives.

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

## Comparison: Dependabot vs Renovate

| Feature | Dependabot | Renovate |
|---------|------------|----------|
| Hosting | GitHub native | Self-hosted or app |
| Configuration | YAML | JSON/JSON5 |
| Grouping | Basic | Advanced |
| Auto-merge | Via workflow | Native `platformAutomerge` |
| Bypass permissions | Via `GITHUB_TOKEN` | Direct (when in bypass list) |
| Lock file maintenance | Manual | Built-in |
| Custom managers | Limited | Regex support |
| Dashboard | Basic | Dependency Dashboard |
| Presets | Limited | Extensive |
| Update types | All | Granular control |
| Rebase on demand | `@dependabot rebase` | `@renovate rebase` |

### When to Use Dependabot
- GitHub-only projects
- Simple dependency management
- Native GitHub integration preferred
- Limited configuration needs

### When to Use Renovate
- Complex grouping requirements
- Multiple repositories
- Advanced auto-merge rules (use `platformAutomerge`)
- Custom package managers
- Dependency Dashboard needed
- Cross-platform support
- Need bypass permissions for auto-merge

## Best Practices

1. **Use Renovate's `platformAutomerge`**: For bypass permissions to work correctly
2. **Avoid `require_code_owner_reviews`**: With dependency auto-merge
3. **Match check names exactly**: In branch protection rules
4. **Use lock file maintenance**: Instead of CI pushing to main
5. **Group related updates**: Reduce PR noise
6. **Use semantic commit prefixes**: Better changelogs
7. **Enable auto-merge for safe updates**: minor/patch/pin/digest
8. **Require CI checks**: Before auto-merge
9. **Review major updates manually**: Breaking changes
10. **Schedule updates**: Off-peak hours
11. **Label PRs**: Easy filtering
12. **Limit concurrent PRs**: Avoid CI overload
13. **Add `workflow_dispatch`**: For manual workflow triggers
