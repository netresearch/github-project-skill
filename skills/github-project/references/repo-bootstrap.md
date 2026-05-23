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
