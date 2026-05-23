# Security Configuration Reference

Repository security best practices: permissions, branch protection, CodeQL, signed commits, and PR merge requirements.

## Least-Privilege Workflow Permissions

All `write` permissions MUST be at **job-level** only. Workflow-level should be `read` or empty.

### Pattern: Workflow-level read, job-level write

```yaml
# CORRECT -- write at job level only
permissions:
    contents: read          # workflow-level: read only

jobs:
    release:
        permissions:
            contents: write  # job-level: narrowed to this job
        steps: ...

    read-only-job:
        permissions:
            contents: read   # job-level: explicit read
        steps: ...

# WRONG -- write at workflow level
permissions:
    contents: read
    pull-requests: write    # Too broad -- move to job level!
```

### Common Workflows That Need Fixing

| Workflow | Typical violation | Fix |
|----------|-------------------|-----|
| `pr-quality.yml` | `pull-requests: write` at top | Move to auto-approve job only |
| `release-labeler.yml` | `issues: write, pull-requests: write` at top | Move to label-release job |
| `create-release.yml` | `contents: write` at top | Move to create-release job |

> **Scorecard note:** The OpenSSF Scorecard Token-Permissions check flags workflow-level `write` permissions.

### Anti-pattern: `permissions: read-all`

`read-all` is the lazy "make Scorecard stop complaining about missing permissions" knob — but it scores **0** on the Token-Permissions check, not full marks. The check wants **explicit, per-permission scopes** so a reviewer can audit what each workflow actually needs.

```yaml
# WRONG — scores 0 on Token-Permissions
permissions: read-all

# RIGHT — explicit scopes, scores 10
permissions:
    contents: read
    # add only what's needed (e.g. pull-requests: read for label/check workflows)
```

If a workflow only reads code, just `contents: read` is enough. Add other read scopes one-by-one as steps need them. Never use `read-all` as a placeholder you mean to tighten "later" — Scorecard treats it as wide-open.

### SLSA Provenance: Use actions/attest-build-provenance (not slsa-github-generator)

`slsa-framework/slsa-github-generator` **cannot be SHA-pinned** — known unfixable limitation ([#4440](https://github.com/slsa-framework/slsa-github-generator/issues/4440), [slsa-verifier#12](https://github.com/slsa-framework/slsa-verifier/issues/12)). Its internal actions use tag refs that conflict with SHA-pinning rulesets.

**Recommended replacement:** `actions/attest-build-provenance` (v4.1.0+), fully SHA-pinnable. For SLSA Build Level 3, host the build workflow as a **reusable workflow in the org `.github` repo** (e.g., `org/.github/.github/workflows/build-go-attest.yml`). This provides true L3 isolation — callers cannot modify the build process.

Verification uses `gh attestation verify` instead of `slsa-verifier`:
```bash
gh attestation verify binary-name --repo OWNER/REPO
```

> **Immutable releases and tags:** GitHub releases are immutable. Once a release is published and deleted, the `tag_name` is permanently locked -- you cannot create a new release on the same tag. Signed tags are cryptographic commitments and must never be deleted or recreated. If a release has issues, bump the version and create a new tag.

### require_last_push_approval + Merge Queue Incompatibility

`require_last_push_approval: true` is **incompatible with merge queues** for solo-maintainer projects. The merge queue creates a new merge commit (a new "push") which dismisses the existing approval. The auto-approve bot cannot re-approve within the merge queue context, permanently blocking PRs.

**Keep `require_last_push_approval: false`** when using merge queues with auto-approve.

### Composite Action Sub-Action Allow-List Gotcha

When a GitHub org has an **Actions allow-list**, composite actions' **internal sub-actions** must ALSO be in the allow-list. Even if the top-level action is permitted (e.g. `ddev/github-action-add-on-test@*`), any `uses:` inside its `action.yaml` must independently pass the org's allow-list check.

**Symptoms:** CI fails at "Set up job" with error listing disallowed actions from inside the composite action.

**Fix options:**
1. Add the sub-actions to the org allow-list (requires org admin)
2. Inline the composite action's steps directly in your workflow using only allowed actions + shell commands
3. Fork/vendor the composite action and replace disallowed sub-actions

**Example:** `ddev/github-action-add-on-test` internally uses `homebrew/actions/setup-homebrew@main` and `mxschmitt/action-tmate@v3` — neither is typically in org allow-lists. Solution: inline the steps (checkout + brew install via shell + bats).

**Tip:** `ubuntu-latest` runners have Homebrew pre-installed. Instead of `homebrew/actions/setup-homebrew`, just add PATH entries:
```bash
printf "%s\n" "/home/linuxbrew/.linuxbrew/bin" "/home/linuxbrew/.linuxbrew/sbin" >> "$GITHUB_PATH"
```

## Branch Protection: Enforce for Admins

`enforce_admins` **SHOULD be `true`** on mature multi-maintainer repos as a hardening target. The [init script](repo-bootstrap.md) ships `false` as the pragmatic baseline — solo-maintainer Netresearch repos benefit from admin-bypass in emergencies (stuck required checks, ruleset races, dependency outages). Once the team has documented its emergency-merge paths and on-call coverage, tighten:

```bash
# Check current state
gh api repos/OWNER/REPO/branches/main/protection --jq '.enforce_admins.enabled'

# Enable enforce_admins (target hardening)
gh api repos/OWNER/REPO/branches/main/protection/enforce_admins -X POST

# Verify
gh api repos/OWNER/REPO/branches/main/protection --jq 'if .enforce_admins.enabled then "OK: Admin enforcement enabled" else "INFO: Admins can bypass branch protection (acceptable on solo-maintainer repos)" end'
```

> **Security note:** Even with `required_conversation_resolution: true`, admins can merge with unresolved review threads if `enforce_admins` is `false`. For repos where the bypass is the safety valve (single maintainer, no on-call), accept the trade-off and discipline-enforce the unresolved-threads check at the operator level (see [the bootstrap reference](repo-bootstrap.md) for the pre-merge GraphQL query operators should run before every `gh pr merge`). For repos with multiple maintainers, both settings should be enabled together.

## Branch Protection: Required Reviews

All projects MUST have `required_approving_review_count >= 1`.

- **Solo maintainer projects:** Use `pr-quality.yml` auto-approve workflow. See `references/auto-merge-guide.md` → "Solo Maintainer" for full setup.
- **Team projects:** Reviews come from team members.

> **Scorecard note:** The OpenSSF Scorecard Branch-Protection check requires `required_approving_review_count >= 1`. Setting it to 0 lowers your score.

## Repository Rulesets vs Branch Protection

Repository rulesets (newer API) offer more granular control than branch protection:

```bash
# List rulesets
gh api repos/OWNER/REPO/rulesets --jq '.[] | {id, name, enforcement}'

# Add pull_request rule to existing ruleset
gh api repos/OWNER/REPO/rulesets/RULESET_ID -X PUT --input - <<'EOF'
{
  "rules": [
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 0,
      "dismiss_stale_reviews_on_push": true,
      "required_review_thread_resolution": true
    }}
  ]
}
EOF
```

### Limitation: Cannot Block on Pending Reviews

Neither branch protection NOR rulesets can block merge when a review is **requested but not yet submitted**.

- `required_approving_review_count: 1` requires an approval (blocks always until approved, not just when pending)
- `required_review_thread_resolution: true` blocks on unresolved threads, not pending reviews
- `copilot_code_review` ruleset triggers review but doesn't block merge while reviewing

**Workaround:** GitHub Actions status check that queries pending reviewers via API and fails if any are outstanding.

## Merge Strategy & Signed Commits

For signed commits workflow (rebase locally + merge commit):

| Repository Setting | Value | Why |
|--------------------|-------|-----|
| `allow_merge_commit` | **true** | Preserves signatures on feature branch commits |
| `allow_rebase_merge` | true | GitHub requires at least one of squash/rebase |
| `allow_squash_merge` | false | Destroys individual commit signatures |

| Branch Protection | Value | Why |
|-------------------|-------|-----|
| `required_signatures` | target: `true`; [init](repo-bootstrap.md): unset | Enforces GPG/SSH signed commits. Init script omits this so Dependabot/Renovate bot PRs aren't blocked before each bot's signing flow is configured per-repo. Turn on once you've verified bot signing works: `gh api repos/OWNER/REPO/branches/main/protection/required_signatures -X POST`. Verify with `gh api repos/OWNER/REPO/branches/main/protection --jq '.required_signatures.enabled'`. |
| `required_linear_history` | **false** | Must be false - conflicts with merge commits |
| `required_conversation_resolution` | true | All review threads must be resolved before merge |

### Workflow

```bash
# 1. Developer rebases PR branch locally (signs commits)
git fetch origin && git rebase origin/main
git push --force-with-lease

# 2. Merge via merge commit (preserves signatures)
gh pr merge <number> --merge
```

### Auto-Merge Compatibility

| Merge Strategy | Works with `required_signatures`? |
|----------------|-----------------------------------|
| Merge commit | Yes - GitHub signs the merge commit |
| Rebase merge | No - GitHub cannot sign rewritten commits |
| Squash merge | No - GitHub cannot sign squashed commit |

**Important:** When enabling auto-merge, select "Create a merge commit" strategy.

For the full merge strategy guide, see `references/merge-strategy.md`.

## CodeQL Configuration

> **Deprecation:** CodeQL Action v3 will be deprecated in December 2026. Migrate all `github/codeql-action/*` references to v4. Check with:
> ```bash
> grep -r 'uses: github/codeql-action/' .github/workflows/ | grep -v '@v4'
> ```

Netresearch projects use custom CodeQL workflows (`.github/workflows/codeql.yml`). GitHub's "Default Setup" **MUST be disabled** -- they cannot coexist.

### The Problem

When both Default Setup and a custom workflow exist, CI fails with:
```
CodeQL analyses from advanced configurations cannot be processed when the default setup is enabled
```

### Required Action

**Before pushing a custom CodeQL workflow**, disable Default Setup:

```bash
# Check current state
gh api repos/OWNER/REPO/code-scanning/default-setup --jq '.state'

# Disable default setup (MANDATORY)
gh api repos/OWNER/REPO/code-scanning/default-setup -X PATCH -f state=not-configured
```

### Verification

```bash
gh api repos/OWNER/REPO/code-scanning/default-setup --jq 'if .state == "not-configured" then "OK: Default Setup disabled" else "FAIL: Default Setup still enabled - DISABLE IT" end'
```

### Supported Languages — PHP Is NOT Supported

CodeQL does **not** support PHP (as of 2026; tracked in [community discussion #158392](https://github.com/orgs/community/discussions/158392)). On a PHP/TYPO3 repo, the only languages worth scanning are:

- `javascript-typescript` — covers JS, TS, and JSX/TSX in `Resources/Public/JavaScript/` and similar
- `actions` — scans `.github/workflows/*.yml` for misconfigurations

A PHP-only repo with neither JS nor non-trivial workflows has **nothing CodeQL can scan** — disabling Default Setup and skipping the custom workflow is correct.

```yaml
# .github/workflows/codeql.yml — PHP/TYPO3 repo
strategy:
  matrix:
    language: [javascript-typescript, actions]   # NOT 'php'
```

If you list `php` in the matrix, the workflow fails at the `init` step with "Unrecognised language: php". If you list `javascript` (the old name), CodeQL Action v3+ rejects it — use `javascript-typescript`.

## Required Reviews from All Requested Reviewers (MANDATORY)

PRs must **not be merged until all requested reviewers have submitted their review**. This includes human reviewers and automated reviewers (e.g., GitHub Copilot). Do not merge while any reviewer's status is still "PENDING".

> **Note:** GitHub branch protection only enforces a *minimum* approval count, not "all requested reviewers must respond." This rule is enforced as a **workflow policy** -- agents and humans must verify before merging.

### Check Reviewer Status Before Merging

```bash
# List all requested reviewers and their review state
gh pr view NUMBER --repo OWNER/REPO --json reviewRequests,reviews --jq '{
  pending: [.reviewRequests[].login],
  completed: [.reviews[] | {user: .author.login, state: .state}]
}'

# GraphQL: full reviewer status (requested + completed)
gh api graphql -f query='query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){pullRequest(number:$pr){
    reviewRequests(first:20){nodes{requestedReviewer{...on User{login}...on Bot{login}}}}
    reviews(last:20){nodes{author{login}state}}
  }}
}' -f owner=OWNER -f repo=REPO -F pr=NUMBER --jq '.data.repository.pullRequest | {
  awaiting: [.reviewRequests.nodes[].requestedReviewer.login],
  reviews: [.reviews.nodes[] | {user: .author.login, state: .state}]
}'
```

If `awaiting` is non-empty, the PR is **not ready to merge** -- those reviewers haven't responded yet.

## Required Conversation Resolution

All review threads on a PR **must be resolved** before merging. Combined with `enforce_admins: true`, this ensures unresolved review threads block **ALL** merges, including those by admins.

```bash
# Enable
gh api repos/OWNER/REPO/branches/main/protection -X PUT \
  --input - << 'EOF'
{
  ...existing settings...,
  "required_conversation_resolution": true
}
EOF

# Verify both conversation resolution AND admin enforcement
gh api repos/OWNER/REPO/branches/main/protection --jq '{
  conversation_resolution: .required_conversation_resolution.enabled,
  enforce_admins: .enforce_admins.enabled
} | if .conversation_resolution and .enforce_admins then "OK: Review threads enforced for all users"
  elif .conversation_resolution then "PARTIAL: Conversation resolution enabled but admins can bypass (enable enforce_admins)"
  else "FAIL: Conversation resolution NOT required - ENABLE IT" end'

# List unresolved threads
gh api graphql -f query='query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){pullRequest(number:$pr){
    reviewThreads(first:50){nodes{id isResolved comments(first:1){nodes{body}}}}
  }}
}' -f owner=OWNER -f repo=REPO -F pr=NUMBER --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | {id, body: .comments.nodes[0].body}'

# Resolve a thread
gh api graphql -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}' -f id=THREAD_NODE_ID
```

## CI Annotations

CI checks can **PASS** while emitting warning annotations (e.g., actionlint/shellcheck via reviewdog, CodeQL deprecation notices). Always check before declaring a PR clean.

```bash
# Find check runs with annotations
gh api "repos/OWNER/REPO/commits/SHA/check-runs" \
  --jq '.check_runs[] | select(.output.annotations_count > 0) | {name: .name, id: .id, annotations: .output.annotations_count}'

# View specific annotations
gh api repos/OWNER/REPO/check-runs/CHECK_RUN_ID/annotations \
  --jq '.[] | {message, annotation_level, path, start_line}'
```

**Prevention:** Configure reviewdog actions with `fail_level: error` (not deprecated `fail_on_error` + `level`).

## PR Merge Checklist

| # | Prerequisite | How to check |
|---|-------------|--------------|
| 1 | All CI checks pass | `gh pr checks NUMBER` |
| 2 | No CI annotations | Check annotations via API (see above) |
| 3 | All requested reviewers responded | `gh pr view NUMBER --json reviewRequests` must be empty |
| 4 | All review threads resolved | GraphQL reviewThreads query |
| 5 | Branch rebased on target | `gh pr view NUMBER --json mergeStateStatus` is `CLEAN` |

## OpenSSF Scorecard Quick Reference

If your Scorecard score is low, check these common issues:

| Scorecard Check | Requirement | Reference |
|----------------|-------------|-----------|
| Token-Permissions | No workflow-level `write` permissions | See "Least-Privilege Workflow Permissions" above |
| Branch-Protection | `required_approving_review_count >= 1` | See "Branch Protection: Required Reviews" above |
| Pinned-Dependencies | All actions pinned to full SHA | Pin with `uses: action@SHA # vX.Y.Z` comment. Use `pin-github-action` tool for batch pinning (see [`org-security-settings.md`](./org-security-settings.md)). Note: composite action sub-actions must also be pinned/allowed (see [Composite Action Sub-Action Allow-List Gotcha](#composite-action-sub-action-allow-list-gotcha)). For transitive dependency risks, see [`reusable-workflow-security.md`](./reusable-workflow-security.md). |
| Code-Review | PRs reviewed before merge | Auto-approve + `required_approving_review_count >= 1` satisfies this |
| SAST | Static analysis enabled | CodeQL workflow (see above) |
