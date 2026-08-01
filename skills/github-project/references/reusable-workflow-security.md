# Reusable Workflow Security Reference

Security model for internal vs external reusable workflows, transitive dependency risks, and audit practices.

## Internal vs External Reusable Workflows

### Internal workflows (`@org/repo/.github/workflows/x.yml@main`)

- Under your organization's control
- OK to reference by branch (`@main`) or tag (`@v1`) -- they are exempt from `sha_pinning_required`
- Changes are visible in your org's commit history
- Trust model: same as trusting your own code

### External workflows (`@actions/*`, `@third-party/*`)

- Maintained by third parties outside your control
- **Must be SHA-pinned** to a full commit hash
- Audit before adoption -- review the workflow source and all transitive dependencies
- Subscribe to security advisories for the action's repository
- Use Dependabot or Renovate to track version updates with SHA pins

## Transitive Dependency Risks

A pinned action can internally reference other actions by tag, creating an unpinned transitive dependency chain.

### The problem

```yaml
# Your workflow: pinned to SHA -- looks secure
- uses: vendor/action@abc123def456  # v0.28

# But inside vendor/action's action.yml:
- uses: vendor/setup-tool@v0.2.1  # TAG -- not pinned!
```

If `vendor/setup-tool@v0.2.1` is compromised (tag moved to malicious commit), your workflow is vulnerable despite pinning the top-level action.

### Real-world example: trivy-action v0.28

The `aquasecurity/trivy-action@v0.28` composite action internally referenced `aquasecurity/setup-trivy@v0.2.1` by tag. A compromise of the `setup-trivy` tag would bypass the SHA pin on `trivy-action`.

### Mitigation

1. **Audit composite actions' `action.yml`** for internal `uses:` directives
2. **Prefer actions that SHA-pin their own dependencies** internally
3. **Fork and vendor** critical actions to control the full dependency chain
4. **Monitor advisories** for both the action and its transitive dependencies

## Audit Checklist for Reusable Workflows

Before adopting a new reusable workflow or action:

- [ ] **Read the source:** Review the workflow/action YAML and any scripts it runs
- [ ] **Check internal refs:** Look for `uses:` inside `action.yml` -- are they SHA-pinned?
- [ ] **Review permissions:** What `permissions` does the workflow request?
- [ ] **Check secrets access:** Does it require secrets? Which ones?
- [ ] **Verify publisher:** Is the action from a verified marketplace creator?
- [ ] **Check maintenance:** Is the repository actively maintained? Last commit date?
- [ ] **Review issues/CVEs:** Any open security issues or past incidents?
- [ ] **Test in isolation:** Run in a fork/test repo before deploying to production

### Audit internal refs of a composite action

```bash
# Download and inspect an action's internal references
gh api repos/OWNER/ACTION/contents/action.yml --jq '.content' | base64 --decode | grep 'uses:'
```

## Shared Workflow Repos Pattern

Centralized CI workflow repositories (e.g., `org/ci-workflows`, `org/skill-repo-skill`) provide consistent CI across many repos.

### Benefits

- **Consistency:** All repos use the same tested CI patterns
- **Maintenance:** Fix once, propagate everywhere via `@main` ref
- **Security:** Audit one repo instead of N copies
- **Standards:** Enforce org-wide policies (linting, testing, signing)

### Maintenance considerations

- **Breaking changes:** Updates to shared workflows affect all consumers immediately (when using `@main`)
- **Versioning:** Use tags (`@v1`, `@v2`) for stability; `@main` for always-latest
- **Testing:** Test workflow changes in a fork before merging to main
- **Documentation:** Document inputs, secrets, and expected behavior for consumers
- **Access control:** Shared workflow repos should have strict branch protection

### Example structure

```
org/ci-workflows/
├── .github/workflows/
│   ├── reusable-lint.yml        # Called by consumer repos
│   ├── reusable-test.yml
│   └── reusable-release.yml
└── README.md
```

Consumer repos reference these as:

```yaml
jobs:
    lint:
        uses: org/ci-workflows/.github/workflows/reusable-lint.yml@main
        with:
            language: go
```

> **See also:** [`org-security-settings.md`](./org-security-settings.md) for org-level SHA pinning and allow-list configuration.

## Never Use `secrets: inherit`

`secrets: inherit` forwards **every** secret available to the calling workflow
into the reusable workflow — and transitively into any action it calls. One
compromised action in the chain (cf. the chain-compromise risk above) then has
access to the full secret set: Docker credentials, publish tokens, signing keys.

Pass only what each workflow needs, explicitly by name:

```yaml
# Bad — hands the whole keyring to the reusable workflow and its dependencies
jobs:
    release:
        uses: org/ci-workflows/.github/workflows/release.yml@<sha>
        secrets: inherit

# Good — least privilege; blast radius limited to the named secrets
jobs:
    release:
        uses: org/ci-workflows/.github/workflows/release.yml@<sha>
        secrets:
            CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}
```

Org secrets do **not** auto-propagate into reusable workflows either — each
caller must forward them explicitly, which is what makes `inherit` look
convenient. Resist it; the explicit form is also the audit trail.

## Gating Your Own Shared-Workflow Repo

The sections above are about auditing **external** actions before you adopt
them. This one is about the shared-workflow repo you **own**: because consumers
reference it at `@main`, every merge ships to all of them instantly — a broken
or insecure merge propagates org-wide before anyone reviews it. Gate `main` and
every PR with more than a linter:

| Dimension | Tool | Catches |
|-----------|------|---------|
| Lint | [actionlint](https://github.com/rhysd/actionlint) | Syntax, expression/input types, shellcheck on `run:` blocks |
| Style | [yamllint](https://github.com/adrienverge/yamllint) `--strict` | YAML conformance |
| Security | [zizmor](https://docs.zizmor.sh/) | Template injection, credential persistence, token misuse, missing cooldown |
| Conformance | small repo script | README ↔ workflow-file sync, `workflow_call`-only triggers, documented inputs |

### zizmor findings you *will* hit, and the correct fix

- **`artipacked` (credential persistence):** every `actions/checkout` on a
  read-only job needs `persist-credentials: false`, or the `GITHUB_TOKEN` is
  written to `.git/config` where any later `run:` step — or a compromised
  npm/composer postinstall — can read it.

  ```yaml
  - uses: actions/checkout@<sha>
    with:
      persist-credentials: false
  ```

- **`template-injection` on `run: ${{ inputs.x }}`:** for a *flag-list* input
  (`render-flags`, `composer-args`), route it through an `env:` var so it is
  never expanded into the script text:

  ```yaml
  - env:
      RENDER_FLAGS: ${{ inputs.render-flags }}
    run: |
      # shellcheck disable=SC2086  # intended word-splitting of a flag list
      tool $RENDER_FLAGS
  ```

  For a *whole-command* input that must be shell-interpreted (`command`,
  `test-unit-command`), env indirection is impossible — the input **is** code.
  Accept it as "code by contract" (set in the caller's committed workflow, the
  same trust level as the code) with a justified inline ignore, and document the
  contract:

  ```yaml
  # Command inputs are code by contract: set in the caller's committed workflow.
  - run: ${{ inputs.command }}  # zizmor: ignore[template-injection]
  ```

  In the input `description:` and the README, state: *command inputs must be
  static literals — never pass `github.event.*` data.* That closes the one real
  injection path the ignore leaves open (a careless consumer piping a PR title
  into the input).

- **`github-app` (unscoped token):** `actions/create-github-app-token` without
  `permission-*` inputs mints a token carrying **all** of the App's granted
  permissions. Scope it to what the job needs: `permission-contents: write`,
  `permission-pull-requests: write`, etc.

### Pin the gate's own tooling

The gate is only as trustworthy as the tools it installs.

- **pip tools** — hash-lock them; don't `pip install foo==1.2.3` bare:

  ```bash
  # requirements.txt generated with: uv pip compile --generate-hashes
  pip install --require-hashes --only-binary ':all:' -r .github/requirements.txt
  ```

  Add a `pip` Dependabot ecosystem (`directory: /.github`) so the pins stay
  fresh.

- **CLI binaries** — download by pinned version and verify the checksum, failing
  closed on mismatch:

  ```bash
  curl -sSfL -o actionlint.tar.gz \
    "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz"
  echo "<sha256>  actionlint.tar.gz" | sha256sum -c -
  tar xzf actionlint.tar.gz actionlint
  ```

  A curl-installed binary is **not** covered by Dependabot — bump its version +
  checksum by hand, and note that in a comment so it is not mistaken for
  auto-maintained. (Do **not** try to pin it via `uses: docker://IMAGE@sha256:…`
  — digest-form `docker://` refs fail workflow startup; see
  [`actionlint-guide.md`](./actionlint-guide.md).)

## Gate a SAST Check on PR-Introduced Findings, Not Ruleset Drift

A SAST step that runs with an auto-updating ruleset (Opengrep/Semgrep
`--config auto`, and similar) and is wired as a **required** merge check has a
trap: the ruleset it fetches drifts over time. Your `main` was green when it was
last scanned; the community then adds a rule; the *next* PR — even a docs-only
one — scans with the newer ruleset, finds pre-existing violations on files it
never touched, and is **blocked from merging** by them. So a contributor's PR is
held hostage by drift on code they didn't write, and it recurs on every repo
sharing the workflow, on any PR.

Two tempting "fixes" are both wrong:

- **Pin the ruleset** (drop `--config auto` for a fixed set) — stops the drift,
  but also stops auto-adoption of new rules. A security scanner that no longer
  learns new issue classes is the wrong trade.
- **Report-only** (upload findings, never fail the check) — stops the blocking,
  but now a PR that genuinely *introduces* a vulnerability sails through. Also
  unacceptable.

The shape that satisfies all three requirements — block real new issues, don't
block on drift, keep adopting new rules — is **diff/baseline-aware gating**: keep
the check blocking, but fail only on findings the PR **introduces relative to the
merge-base**, not on the repo's accumulated state.

- A real new vuln → present at the PR head, absent at baseline → **fails.**
- A pre-existing finding / drift on untouched files → present at *both* → **passes.**
- `--config auto` still pulls the latest rules, so a newly-added rule still
  catches a newly-introduced violation.

Two mechanisms:

- **Scanner baseline:** Semgrep supports `--baseline-commit <merge-base>` (fail
  only on findings introduced since that commit). **Verify the exact flag against
  the scanner you actually run** — a fork (e.g. Opengrep) may name or support it
  differently; do not assume it is identical.
- **GitHub-native:** upload the SARIF to code scanning and let the **Code
  Scanning PR check** gate — GitHub can be set to fail the check only on alerts
  **introduced by the PR**, which is diff-aware without a CLI flag.

Symptom that you have this problem: a required SAST check flips a *docs* or
otherwise-unrelated PR from green to red, and the findings are all on files the
PR never touched. To read them, list the analyses via
`repos/OWNER/REPO/code-scanning/analyses?ref=refs/pull/<PR>/merge`, take the
newest analysis `id`, then fetch that analysis's SARIF —
`gh api repos/OWNER/REPO/code-scanning/analyses/<id> -H 'Accept: application/sarif+json'`
— and inspect the result locations. Fix the reusable workflow, not the innocent PR.

## Some things should not be a reusable — the security gates are telling you

Before wrapping an action in a shared workflow, ask whether the wrapper *fights*
the org's own scanners. Two patterns that surfaced against zizmor + CodeQL:

**A reusable that runs a caller-supplied script.** A generic "ssh-deploy" that
executes `inputs.script` on a remote host is flagged by both zizmor
(*template-injection*) and CodeQL (*code injection*) — **by design**, because a
reusable input is attacker-influenceable if a caller ever wires it to an
untrusted trigger. Routing the script through `env:` (`env.X`) silences zizmor
but **not** CodeQL, which still traces `env.X ← inputs.script`. The gate is
correct: a run-arbitrary-caller-code leaf is exactly what the injection rules
exist to prevent. If the value the reusable adds is only "centralise one
infrequently-bumped action," the honest call is often to **keep the single
pinned action inline** as a documented exception rather than suppress security
alerts on a production-deploy reusable.

**Prefer the runner's `gh` CLI over wrapping a third-party release action.**
zizmor flags `softprops/action-gh-release` with *"action functionality is
already included by the runner: use `gh release` in a script step."* Rewriting
the reusable to `gh release create`/`edit` (with the notes body passed through
`env` and written via `--notes-file`) is both zizmor- and CodeQL-clean **and**
leaves **zero external actions** in the chain — the ideal end state for an
"actions live only in shared workflows" policy. General rule: if the runner
already ships a CLI that does the job (`gh`, `docker`, `cosign`), a reusable
built on that CLI beats one that pins yet another third-party action.
