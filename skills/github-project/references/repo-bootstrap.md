# Repository Bootstrap — Required First Step After `gh repo create`

After creating any new Netresearch repository — `gh repo create`, push your initial commit, **then before opening the first PR** — you MUST apply branch protection. (The default branch ref must exist; the script exits 4 on empty repos.) Without this, the unresolved-threads workflow rule is unenforceable — operator discipline alone has demonstrably failed.

**Concrete incident:** [netresearch/snipe-it-docker-compose-stack#17](https://github.com/netresearch/snipe-it-docker-compose-stack/pull/17). The repo was created mid-session, branch protection was never applied, and three of the next eight merged PRs shipped with unresolved bot-reviewer threads — including a HIGH-severity token leak that both Copilot and gemini-code-assist had flagged. The structural enforcement (`required_conversation_resolution: true`) would have blocked those merges. The skill had the docs; nothing prompted the apply.

## Two-step flow

```bash
# 1. Immediately after `gh repo create` and the first push:
bash <skill-root>/skills/github-project/scripts/init-branch-protection.sh OWNER/REPO
#    Applies the baseline:
#      required_conversation_resolution: true   (load-bearing)
#      required_approving_review_count:  1
#      allow_force_pushes:               false
#      allow_deletions:                  false
#      required_linear_history:          false   (needed for merge-commit
#                                                 signing strategy)
#    Required status checks are intentionally NOT set yet — a brand-new repo
#    has no CI history to discover context names from.

# 2. After the first CI run completes on the default branch:
bash <skill-root>/skills/github-project/scripts/init-branch-protection.sh OWNER/REPO --from-current-checks
#    Discovers successful check-run names from /commits/{default}/check-runs
#    and PATCHes them in as required contexts with strict=true.
```

The script is idempotent: re-running on an already-compliant repo reports `already compliant` and exits 0. Drift on opinionated fields exits 1 with a per-field diff (no silent clobber of admin choices).

## Deliberately permissive knobs

- **`enforce_admins`** — explicitly `false` in the template. Solo-maintainer Netresearch repos (snipe-it-docker-compose-stack, ldap-selfservice-…, usercentrics-widgets, etc.) need admin bypass for emergency response. Tighten per-repo once the team validates the workflow:
  ```bash
  gh api repos/OWNER/REPO/branches/DEFAULT/protection/enforce_admins -X POST
  ```
- **`required_signatures`** — *omitted entirely* from the template (not set to `false`). PUTting the template would otherwise reset repos that have already opted into signing. The script never touches this field. Tighten per-repo:
  ```bash
  gh api repos/OWNER/REPO/branches/DEFAULT/protection/required_signatures -X POST
  ```

Both knobs flip to `true` only after the team has signing infrastructure for bot accounts (Dependabot, Renovate) so those PRs don't immediately get blocked.

## Verification

Read-only audit of an existing repo:

```bash
gh api repos/OWNER/REPO/branches/$(gh api repos/OWNER/REPO --jq .default_branch)/protection \
  --jq '.required_conversation_resolution.enabled // false'
```

Or invoke `/assess github-project` — checkpoint `GH-31` fails with `severity: error` if `required_conversation_resolution` is not enabled, with a `desc:` that names this exact failure mode.

## Gap NOT closed by the baseline

GitHub branch protection cannot block on *requested-but-pending* reviews (Copilot is mid-review, you merge anyway). The baseline closes the **unresolved-threads** class (which is what snipe-it#17 slipped through), not the **pending-reviewer** class. The pending-reviewer gap is a workflow-discipline rule audited via the GraphQL `reviewRequests` check before any merge — see `references/security-config.md` § "Required Reviews from All Requested Reviewers".

## Script exit codes

| Code | Meaning |
|------|---------|
| 0    | Applied, or already compliant |
| 1    | Drift detected on opinionated fields (per-field diff printed); script refuses to clobber |
| 2    | Invalid arguments / template missing |
| 3    | Repo not found or no API access |
| 4    | Default branch ref does not yet exist (empty repo — push first) |
| 5    | `--from-current-checks`: no completed CI run on default branch |

## Actions & Security Hardening (apply alongside branch protection)

`init-branch-protection.sh` covers branch protection only. A repo's **Actions permissions** and **security toggles** are a separate API surface that GitHub ships at insecure defaults: `GITHUB_TOKEN` read/write, workflows may approve PRs, no SHA-pinning, all actions allowed. Apply these in the same bootstrap step.

> **Org members:** if the org already sets these at `orgs/ORG/actions/permissions` (see [`org-security-settings.md`](org-security-settings.md)) the repo inherits them — the per-repo commands below are for standalone repos, or repos under a permissive org default. (Endpoint shapes verified against [AriESQ/gh-safe-repo](https://github.com/AriESQ/gh-safe-repo).)

### Workflow token: read-only, no self-approval

```bash
gh api repos/OWNER/REPO/actions/permissions/workflow -X PUT \
  -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=false
```

- `default_workflow_permissions=read` — `GITHUB_TOKEN` defaults to read-only; jobs needing write opt in at job level (see [`security-config.md`](security-config.md) § Least-Privilege Workflow Permissions). GitHub's default is `write`.
- `can_approve_pull_request_reviews=false` — stops a workflow from approving its own PRs (which would otherwise satisfy `required_approving_review_count` without a real reviewer).

> **Interaction 1 — read-only token + reusable-workflow callers.** Once the default
> is `read`, a caller **job** that calls a reusable workflow and omits its own
> `permissions:` block inherits read-only and **fails at startup** (`startup_failure`,
> before any step) if the reusable declares a permission it wasn't granted. Symptom:
> a whole workflow shows `startup_failure` with no logs. Fix: give each caller job an
> explicit `permissions:` matching the reusable's documented caller requirements
> (e.g. `contents: read` + `security-events: write` for the security reusables). This
> bit the netresearch security.yml callers after hardening.
>
> **Interaction 2 — `can_approve_pull_request_reviews=false` disables auto-approve.** If the repo uses a
> `pr-quality`-style **auto-approve** workflow (solo-maintainer flow) or **dependabot
> auto-merge** with `required_approving_review_count >= 1`, those rely on a workflow
> approving the PR. Setting `can_approve_pull_request_reviews=false` silently breaks
> them — PRs then stick on `REVIEW_REQUIRED` and dependabot PRs never auto-merge.
> **Keep `can_approve_pull_request_reviews=true`** when you use auto-approve/auto-merge; the
> least-privilege win is already carried by `default_workflow_permissions=read`.

### Restrict which actions can run + require SHA pinning

```bash
# Allow only GitHub-owned + verified-creator actions, and require SHA pins.
# enabled=true is REQUIRED in this body or the PUT returns 422.
gh api repos/OWNER/REPO/actions/permissions -X PUT \
  -F enabled=true \
  -f allowed_actions=selected \
  -F sha_pinning_required=true

# Allow-list — only valid AFTER allowed_actions=selected (apply order matters):
gh api repos/OWNER/REPO/actions/permissions/selected-actions -X PUT --input - <<'EOF'
{ "github_owned_allowed": true, "verified_allowed": true, "patterns_allowed": ["OWNER/*"] }
EOF
```

- `sha_pinning_required=true` is the repo-level twin of the org setting — workflows must pin actions to a full commit SHA. Reusable-workflow `@main`/`@vX` refs are exempt; see [`reusable-workflow-security.md`](reusable-workflow-security.md).

### Fork-PR approval (public repos only)

Holds fork PRs — and the Actions minutes they would burn — until a maintainer approves. The endpoint exists only for public repos (returns null/404 on private):

```bash
gh api repos/OWNER/REPO/actions/permissions/fork-pr-contributor-approval -X PUT \
  -f approval_policy=all_external_contributors
```

| `approval_policy` | Who needs approval before fork-PR workflows run |
|---|---|
| `first_time_contributors_new_to_github` | Brand-new GitHub accounts only (GitHub default) |
| `first_time_contributors` | First-time contributors to this repo |
| `all_external_contributors` | Every external contributor (safest) |

**From the contributor side, this looks like a broken PR.** Every workflow reports `action_required` — `completed/action_required`, not `failure` — and `gh pr checks` shows only the handful of jobs that run without approval (`pull_request_target` ones, e.g. a PR-title linter). Nothing is wrong and there is nothing to fix; a maintainer has to click *Approve and run workflows*. Confirm rather than guess:

```bash
gh api "repos/OWNER/REPO/actions/runs?event=pull_request" \
  --jq '.workflow_runs[] | select(.head_branch=="MY-BRANCH")
        | "\(.name): \(.status)/\(.conclusion)"'
```

A uniform `completed/action_required` across every workflow is the approval gate, not a red build. Do not push "fix CI" commits at it.

### Security toggles

```bash
# Dependabot alerts + automatic security-update PRs (bodyless PUTs)
gh api repos/OWNER/REPO/vulnerability-alerts -X PUT
gh api repos/OWNER/REPO/automated-security-fixes -X PUT

# Private vulnerability reporting — a STANDALONE PUT, not a security_and_analysis field
gh api repos/OWNER/REPO/private-vulnerability-reporting -X PUT

# Secret-scanning push protection (paid/private; auto-on for public).
# secret_scanning MUST be sent alongside push protection or the PATCH is silently ignored.
gh api repos/OWNER/REPO -X PATCH --input - <<'EOF'
{ "security_and_analysis": {
    "secret_scanning": { "status": "enabled" },
    "secret_scanning_push_protection": { "status": "enabled" } } }
EOF
```

> **Plan gate:** rulesets, Dependabot, and secret scanning are unavailable on **free-plan private** repos — the API returns 403 (you can't even `GET .../rulesets`). Public repos and paid plans (the Netresearch org) get all of it. If a toggle 403s, check the repo's plan/visibility before debugging the call. More scripting quirks: [`security-config.md`](security-config.md) § GitHub Security API.
