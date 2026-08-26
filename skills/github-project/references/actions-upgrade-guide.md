# GitHub Actions Upgrade Guide

Read this when bumping SHA-pinned actions across majors — a Renovate major PR,
or a manual sweep after a security advisory. It covers the one systemic change
driving most current majors (the Node-runtime wave), the upgrade procedure for
SHA pins, and the verified breaking changes per common action.

Version facts and dates below were verified against the actions' release notes
and the GitHub changelog on **2026-08-26**. Versions age; the procedure does
not. Re-resolve current versions at upgrade time instead of trusting any table,
this one included.

## The Node-runtime wave (2025–2026)

GitHub is removing the Node 20 action runtime
([changelog, 2025-09-19](https://github.blog/changelog/2025-09-19-deprecation-of-node-20-on-github-actions-runners/),
dates since revised):

- Since **2026-06-16**, runners execute `runs.using: node20` actions on Node 24
  by default.
- On **2026-09-23**, Node 20 is removed from the runner. Actions still
  declaring `node20` and incompatible with Node 24 break outright.
- Opt in early per workflow with `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true`.

Nearly every 2026 major of the common actions is this same change wearing the
action's own version number: the action moves to `runs.using: node24`, which
**requires Actions Runner ≥ 2.327.1**. On GitHub-hosted runners that floor is
long met — just bump. On **self-hosted runners, update the runner first**, or
every bumped action fails at startup. Node 24 itself does not support
macOS ≤ 13.4 or ARM32 self-hosted runners.

Many of the same majors also migrated to ESM. That is transparent to callers —
it only matters when you maintain a fork of the action.

## Upgrade procedure for SHA-pinned actions

Pinning conventions (`uses: owner/action@SHA # vX.Y.Z`, batch tooling) live in
[`security-config.md`](./security-config.md) and
[`org-security-settings.md`](./org-security-settings.md). For the bump itself:

1. **Resolve the real current major from the tag list, never from a
   "latest release" endpoint** — point releases for old majors land later and
   take the latest-release slot (observed 2026-08-26: `actions/download-artifact`
   answered `v3.1.0-node20` as latest release while the current major was v8).

   ```bash
   gh api "repos/OWNER/ACTION/releases?per_page=15" --jq '.[].tag_name' | sort -Vr | head -5
   ```

2. **Read the release notes of every major you cross**, not only the target:

   ```bash
   gh api repos/OWNER/ACTION/releases/tags/vX.0.0 --jq .body
   ```

3. **Resolve tag → SHA and keep the comment in sync** — the comment is what
   humans and Renovate read; a stale comment is worse than none:

   ```bash
   gh api repos/OWNER/ACTION/commits/vX.Y.Z --jq .sha
   ```

4. **Verify**: `actionlint` on the changed workflows
   ([`actionlint-guide.md`](./actionlint-guide.md)), zizmor where wired, and
   watch the first run on a PR — a runtime floor violation only surfaces at
   execution.

Renovate bumps SHA and comment together on its own; a major still needs step 2
before approving the PR.

## Breaking changes by action

Verified from release notes, 2026-08-26. "Runner ≥ 2.327.1" is shorthand for
the Node 24 runtime change described above.

| Action | Current | Major | What changes |
|---|---|---|---|
| `actions/checkout` | v7.0.1 | v6 | Credentials persisted to a separate file instead of `.git/config` ([#2286](https://github.com/actions/checkout/pull/2286)) — anything reading the token out of `.git/config` stops finding it |
| | | v7 | Checkout of a fork PR head is **blocked for `pull_request_target` and `workflow_run` events** ([#2454](https://github.com/actions/checkout/pull/2454)); workflows that deliberately check out fork code on those triggers must be restructured. ESM |
| `actions/cache` | v5.1.0 | v5 | Node 24, runner ≥ 2.327.1 |
| `actions/download-artifact` | v8.0.1 | v5 | **Breaking path behavior** for single-artifact downloads by ID ([#416](https://github.com/actions/download-artifact/pull/416)) |
| | | v6–v7 | Node 24 (v7 makes it the default runtime), runner ≥ 2.327.1 |
| | | v8 | ESM; **hash mismatches now error by default** (overridable per release notes) |
| `actions/upload-artifact` | v7.0.1 | v6 | Node 24 default, runner ≥ 2.327.1 |
| | | v7 | ESM; new `archive: false` uploads a single file unzipped (`name` input ignored in that mode) |
| `actions/setup-node` | v7.0.0 | v7 | ESM; adds `cache-primary-key`/`cache-matched-key` outputs — no caller-facing break found in the notes |
| `ramsey/composer-install` | 4.0.0 | v4 | Internal `actions/cache` v5 → runner ≥ 2.327.1 (breaking for self-hosted only) |
| `docker/setup-buildx-action` | v4.3.0 | v4 | Node 24, runner ≥ 2.327.1; **removes deprecated inputs/outputs** ([#464](https://github.com/docker/setup-buildx-action/pull/464)); ESM |
| `docker/login-action` | v4.6.0 | v4 | Node 24, runner ≥ 2.327.1; ESM |
| `step-security/harden-runner` | v2.21.0 | — | Still on the v2 line, no major crossed |

The absence of a row is not evidence of a painless upgrade — it means the
action was not checked on 2026-08-26. Run step 2 of the procedure.
