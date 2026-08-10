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

## Secret Scanning: A Config File Replaces the Ruleset

gitleaks does **not** merge your config with its built-in rules. A
`.gitleaks.toml` that declares only an allowlist declares *no rules at all*, and
the scan then matches nothing — reporting `no leaks found` for every input,
including a live credential sitting in the diff.

```toml
# Without this block, everything below replaces the defaults
# instead of extending them.
[extend]
useDefault = true

[allowlist]
paths = ['''testdata/''']
```

The failure is invisible by construction: a scanner that finds nothing looks
exactly like a clean repository. A green secret-scanning check is therefore not
evidence of anything until you have seen it fail once.

**Verify by planting one.** Write a value matching a rule you expect to fire
into a scratch file **outside the repository** and confirm the scan reports it:

```bash
# Assemble the probe so no secret-shaped literal is ever committed.
printf 'token = "%s-1234567890-abcdefghijklmnopqrstuvwx"\n' 'xoxb' \
  > /tmp/leak-probe.txt
gitleaks dir /tmp --no-banner        # expect: leaks found: 1
```

Keep the probe out of the repository, and out of the documentation too:
GitHub's push protection scans what you push and will **block a commit that
merely documents a realistic-looking token** — including a page explaining how
to test secret scanning. The block is correct behaviour; work around it by
assembling the value at runtime rather than by requesting an exemption.

Three traps when testing:

- **Well-known example credentials are allowlisted upstream.** AWS's
  `AKIAIOSFODNN7EXAMPLE` and friends will not be reported no matter what.
  Use a value that is not in anyone's allowlist.
- **gitleaks auto-discovers a config in the scanned directory.** Copying the
  repo's `.gitleaks.toml` next to the probe file silently re-applies the config
  you were trying to test without.

Also distinguish the two scan modes: `gitleaks dir` scans the working tree,
`gitleaks git` scans history. A repo can be clean on disk and still carry a
credential in a commit from months ago — and replacing the file does not remove
it from history, so a leaked credential still needs rotating.

## OpenSSF Scorecard Quick Reference

If your Scorecard score is low, check these common issues:

| Scorecard Check | Requirement | Reference |
|----------------|-------------|-----------|
| Token-Permissions | No workflow-level `write` permissions | See "Least-Privilege Workflow Permissions" above |
| Branch-Protection | `required_approving_review_count >= 1` | See "Branch Protection: Required Reviews" above |
| Pinned-Dependencies | All actions pinned to full SHA | Pin with `uses: action@SHA # vX.Y.Z` comment. Use `pin-github-action` tool for batch pinning (see [`org-security-settings.md`](./org-security-settings.md)). Note: composite action sub-actions must also be pinned/allowed (see [Composite Action Sub-Action Allow-List Gotcha](#composite-action-sub-action-allow-list-gotcha)). For transitive dependency risks, see [`reusable-workflow-security.md`](./reusable-workflow-security.md). |
| Code-Review | PRs reviewed before merge | Auto-approve + `required_approving_review_count >= 1` satisfies this |
| SAST | Static analysis enabled | CodeQL workflow (see above) |

## GitHub Security API: Scripting Gotchas

Endpoint quirks when scripting repo security settings, verified against the GitHub REST spec (source: [AriESQ/gh-safe-repo](https://github.com/AriESQ/gh-safe-repo)). For the bootstrap commands these annotate, see [`repo-bootstrap.md`](repo-bootstrap.md) § Actions & Security Hardening.

- **`PATCH /repos/{o}/{r}` can 404 immediately after `POST /user/repos`.** Repo creation is eventually consistent — the object exists but isn't routable for settings updates for a brief window. Retry the PATCH with backoff (e.g. 1s/2s/4s) when it directly follows a create; standalone PATCHes don't need it.
- **"Enabled?" probe status is not uniformly 204.** `GET .../vulnerability-alerts` returns **204** when enabled, but `GET .../private-vulnerability-reporting` and `GET .../automated-security-fixes` return **200**. Test the **2xx range** (`200 <= status < 300`), not `== 204`, or the probe is wrong for half the endpoints.
- **`secret_scanning_push_protection` is silently ignored unless `secret_scanning` is in the same PATCH.** Send both keys in the `security_and_analysis` body together.
- **Grouped security updates, automatic dependency submission, and dependency graph have no per-repo REST API.** They exist only as org-level code-security configuration fields (`/orgs/{org}/code-security/configurations`) and in the UI. A `PATCH /repos security_and_analysis` with `dependency_graph_autosubmit_action` returns 200 but is silently ignored. For per-repo grouped security updates use `dependabot.yml` groups (see [`dependency-management.md`](dependency-management.md)).
- **Free-plan private repos 403 on all ruleset / Dependabot / secret-scanning APIs** — you can't even `GET .../rulesets`. Public repos and paid plans (the Netresearch org) are unaffected.

## SonarCloud: automatic analysis reads `.sonarcloud.properties`, not `sonar-project.properties`

Exclusions placed in `sonar-project.properties` are **silently inert** under
automatic analysis — the mode every Netresearch repository uses, since none runs
a scanner in CI. Per the SonarQube Cloud docs: *"If you import a project that
already contains a `sonar-project.properties` file, SonarQube Cloud will ignore
the parameters in your `sonar-project.properties` file."* That file is what a
**CI-run scanner** reads; automatic analysis reads `.sonarcloud.properties` on
the default branch.

The failure is quiet and looks like a code problem. One repo carried

```properties
sonar.exclusions=data/**
sonar.cpd.exclusions=data/**
```

in `sonar-project.properties` for months while the duplication gate kept failing
on exactly those files — 50 % on one PR, 91.5 % on the next, against a 3 %
threshold — and both had to be merged with a red gate. Renaming the file (same
two settings, byte-identical) moved the project from 40 analysed files to 32,
and duplicated lines from 2188 to 0.

```bash
# Are exclusions set server-side instead? (empty result = nothing configured)
curl -fsSL "https://sonarcloud.io/api/settings/values?component=KEY&keys=sonar.exclusions,sonar.cpd.exclusions" \
  | jq '.settings'
# Which files does Sonar actually analyse? Grep the paths you meant to exclude.
curl -fsSL "https://sonarcloud.io/api/components/tree?component=KEY&qualifiers=FIL&ps=500" \
  | jq -r '.components[].path' | grep '^data/'
```

Diagnose in that order — a *present* `sonar-project.properties` plus *empty*
server-side settings plus the excluded paths still showing up in the file tree
is the signature. Do not reshape the diff to satisfy the gate: fixture data,
generated files and database seeds are duplicated by design. If the project ever
switches to a CI-run scanner, the file has to be renamed back.

## SonarCloud Quality Gate: PR (new code) vs Branch (overall)

A PR can pass SonarCloud's **new-code** quality gate (0 new issues) yet turn the
**default-branch** gate **red after merge** — the two gates evaluate different
conditions. The branch gate adds conditions the PR analysis doesn't, most often
`new_security_hotspots_reviewed` (must be **100%**) and overall coverage.

- **Security Hotspots need *reviewing*, not fixing.** They are security-sensitive
  code flagged for a human to mark **Safe** / **Fixed** in the SonarCloud UI (or
  via `POST api/hotspots/change_status`). An unreviewed hotspot fails the gate even
  though it is not a bug.
- **The offenders are frequently pre-existing**, in files the PR never touched
  (e.g. `curl | bash`, shell `[ ]`, a regex). Don't assume the merged PR caused it
  — confirm against the hotspot list first.

```bash
# which branch-gate condition failed
curl -fsSL "https://sonarcloud.io/api/qualitygates/project_status?projectKey=KEY&branch=main" \
  | jq '.projectStatus.conditions[]? | select(.status != "OK")'
# the to-review hotspots (verify before blaming the merge)
curl -fsSL "https://sonarcloud.io/api/hotspots/search?projectKey=KEY&branch=main&status=TO_REVIEW&ps=30" \
  | jq -r '.hotspots[]? | "\(.component | sub(".*:"; "")):\(.line // "?") \(.securityCategory // "")"'
```

## Effective Branch Rules

Reading what a branch actually enforces, and auditing whether a required check
can fail.

### Two rule sources, and only one of them is obvious

A branch can be governed by **classic branch protection** and by **rulesets**
at the same time. GitHub composes them and applies the most restrictive result.
The classic endpoint cannot see rulesets, so reading it alone reports a branch
as unprotected that is in fact fully gated:

```bash
# Classic protection — returns real values, but is BLIND to rulesets
gh api repos/OWNER/REPO/branches/main/protection

# Rulesets — the effective rules from every active ruleset on the branch
gh api repos/OWNER/REPO/rules/branches/main
```

Observed on a repository where both were configured:

| Field, classic endpoint | Reads as | Reality (rulesets) |
|---|---|---|
| `required_status_checks: null` | nothing is required | 23 required contexts |
| `required_approving_review_count: 0` | no review required | 1 required approval |
| `required_conversation_resolution: true` | correct | also required |
| `enforce_admins: false` | correct | plus per-ruleset bypass actors |

The two failure shapes are asymmetric and both are bad:

- **`null` reads as "not configured".** `required_status_checks` is absent from
  the classic payload entirely when a ruleset supplies the checks.
- **`0` reads as a real answer.** `required_approving_review_count: 0` is the
  *classic* setting, not the effective one. Nothing in the response says a
  ruleset requires 1.

A compliance document was written off the classic endpoint alone and attested
that the repository required neither review nor status checks. Both statements
were false, and nothing in the response hinted at it.

**Read both. When they disagree, the effective answer is the more restrictive
one.** Name which endpoint a claim came from whenever the claim lands in a
document, an issue or a PR body.

### Bypass actors live on the ruleset, not on the branch

`enforce_admins` covers classic protection only. Rulesets carry their own list:

```bash
gh api repos/OWNER/REPO/rulesets/RULESET_ID \
  --jq '{name, enforcement, bypass: [.bypass_actors[]? | {actor_type, actor_id, bypass_mode}]}'
```

`bypass_mode: always` lets the actor push straight past the rule;
`pull_request` lets it merge a pull request that does not satisfy it. The REST
API returns `actor_id` as a number and does not resolve it to a role name — say
"repository role id 5" rather than guessing "admin" unless you resolved it.

### Auditing whether a required check can actually fail

A context being in the required list does not mean it gates anything.

### A required check that is always skipped enforces nothing

```bash
gh api "repos/OWNER/REPO/commits/SHA/check-runs?per_page=100" \
  --jq '.check_runs[] | "\(.conclusion // .status)\t\(.name)"' | sort -u
```

Cross-check every required context against that list. A context whose
conclusion is `skipped` on every commit is a requirement that no state of the
code can violate. Observed case: `fuzz / Fuzz Tests` was required and always
skipped, because the job that produced it passed no inputs to its reusable
workflow and the suite defaulted to off. The job that actually ran the suite was
a different context and was not required at all.

### Check-run names come from the JOB name, not the workflow

Two jobs calling the same reusable workflow produce check-runs under
**different** prefixes, because the prefix is the calling job's name:

```yaml
# .github/workflows/checks.yml
jobs:
  fuzz:            # -> "fuzz / Fuzz Tests"
    uses: org/reusables/.github/workflows/fuzz.yml@main

# .github/workflows/ci.yml
jobs:
  fuzz-mutation:   # -> "fuzz-mutation / Fuzz Tests"
    uses: org/reusables/.github/workflows/fuzz.yml@main
    with: { run-fuzz-tests: true }
```

The two names look interchangeable and are not. Do not infer which workflow
emits a context — measure it:

```bash
for id in $(gh run list --repo OWNER/REPO --commit SHA --limit 30 --json databaseId --jq '.[].databaseId'); do
  wf=$(gh api repos/OWNER/REPO/actions/runs/$id --jq .path)
  gh api "repos/OWNER/REPO/actions/runs/$id/jobs?per_page=100" --jq '.jobs[].name' \
    | sed "s|^|$(basename "$wf")\t|"
done | sort -u
```

### A gate job is only worth requiring if it reads its own `needs`

Requiring one aggregate context instead of many is a good pattern — it makes a
job that is missing from `gate.needs` the only failure mode, rather than a
silent coverage loss. It is only sound if the gate actually evaluates its
dependencies:

```yaml
- name: Fail unless every job succeeded or was skipped
  env:
    RESULTS: ${{ toJSON(needs) }}
  run: |
    bad=$(jq -r 'to_entries[] | select(.value.result != "success" and .value.result != "skipped") | "\(.key)=\(.value.result)"' <<<"$RESULTS")
    [ -z "$bad" ] || { echo "::error::gate failed — $bad"; exit 1; }
```

Read the gate's steps before requiring it. A job with `if: always()` and no
result evaluation is a green rubber stamp, and requiring it would be worse than
requiring nothing. Treating `skipped` as passing is deliberate: jobs skipped by
an event gate must not block the merge queue.

### Before changing a required-context list

1. Back up the ruleset: `gh api repos/OWNER/REPO/rulesets/ID > backup.json`.
2. Confirm every context you are about to require reports on `merge_group`, not
   only on `pull_request` — requiring a context the queue never produces wedges
   the queue for everyone.
3. Apply with `gh api -X PUT repos/OWNER/REPO/rulesets/ID --input new.json`.
4. Read the effective list back from `rules/branches/BRANCH` and confirm the
   next pull request reports every newly required context.
