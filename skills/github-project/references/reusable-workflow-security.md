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
