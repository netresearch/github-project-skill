# Tag-Version Validation Reference

**Purpose:** Document patterns for validating that version tags match in-repo version files, working around GitHub.com's lack of server-side pre-receive hooks.

## The Problem

GitHub.com (cloud) does not support custom **pre-receive hooks** — those are only available on GitHub Enterprise Server. This means you cannot reject a tag push server-side based on custom validation logic (e.g., checking that a tag matches a version file).

## Defense-in-Depth Pattern

Use two layers of protection:

1. **Local git hook** (pre-push) — catches mistakes before they leave the developer's machine
2. **CI validation step** — catches anything that slips through (force-push, web UI tag creation, etc.)

```
Developer                     GitHub
    │                            │
    ├─ git tag 1.2.3             │
    ├─ git push --tags           │
    │   └─ pre-push hook ─ FAIL  │  ← Local gate
    │      "version mismatch"    │
    │                            │
    ├─ fix version, amend, push  │
    │   └─ pre-push hook ─ PASS ─┼─► tag pushed
    │                            │
    │                            ├─ CI workflow triggered
    │                            ├─ Validate version ─ PASS ← Safety net
    │                            └─ Publish/deploy
```

## Local Pre-Push Hook

Generic pattern for any project with a version file:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Find semver tags at HEAD (with or without v prefix), normalize to bare version
TAGS=$(git tag --points-at HEAD | sed -nE 's/^v?([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' || true)
[[ -z "${TAGS}" ]] && exit 0

# Extract version from your version file (adapt sed pattern per project)
FILE_VERSION=$(sed -nE "s/.*'version'[[:space:]]*=>[[:space:]]*'([^']+)'.*/\1/p" version-file.ext)

if [[ -z "${FILE_VERSION}" ]]; then
    echo "ERROR: Could not extract version from version-file.ext"
    exit 1
fi

# Check if file version matches any of the tags at HEAD
if ! echo "${TAGS}" | grep -qFx "${FILE_VERSION}"; then
    echo "ERROR: version file (${FILE_VERSION}) does not match any semver tag at HEAD"
    echo "Tags found at HEAD:"
    echo "${TAGS}"
    exit 1
fi
```

### Integration with CaptainHook

```json
{
    "pre-push": {
        "enabled": true,
        "actions": [
            { "action": "Build/Scripts/check-tag-version.sh" }
        ]
    }
}
```

## CI Validation Step (GitHub Actions)

Add **before** any publish/deploy step:

```yaml
- name: Validate version file matches tag
  env:
    TAG_VERSION: ${{ env.version }}
  run: |
    FILE_VERSION=$(sed -nE "s/.*'version'[[:space:]]*=>[[:space:]]*'([^']+)'.*/\1/p" version-file.ext)
    if [[ -z "${FILE_VERSION}" ]]; then
      echo "::error file=version-file.ext::Could not extract version from version-file.ext"
      exit 1
    fi
    if [[ "${TAG_VERSION}" != "${FILE_VERSION}" ]]; then
      echo "::error file=version-file.ext::Tag (${TAG_VERSION}) does not match version file (${FILE_VERSION})"
      exit 1
    fi
    echo "Version validated: ${TAG_VERSION}"
```

## Common Version File Patterns

| Ecosystem | File | Extraction |
|-----------|------|------------|
| TYPO3 | `ext_emconf.php` | `sed -nE "s/.*'version'[[:space:]]*=>[[:space:]]*'([^']+)'.*/\1/p"` |
| Node.js | `package.json` | `jq -r .version` |
| Python | `pyproject.toml` | `sed -nE 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p'` |
| Go | `version.go` | `sed -nE 's/.*Version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p'` |
| Rust | `Cargo.toml` | `sed -nE 's/^version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p'` |
| Claude Code Plugin | `.claude-plugin/plugin.json` | `python3 -c "import json; print(json.load(open('.claude-plugin/plugin.json'))['version'])"` |

## Composer Audit Blocking Installs

Composer 2.7+ blocks `composer install/require` if a dependency has a known security advisory (exit code 2). This can break CI even when the advisory is in a transitive dependency you don't control.

**Temporary exemption in `composer.json`:**
```json
{
    "config": {
        "audit": {
            "ignore": {
                "PKSA-xxxx-yyyy": "Upstream issue via dependency-name, no fix available yet"
            }
        }
    }
}
```

Remove the exemption once the upstream fix is released.

## Batch PR Merging Gotchas

When merging PRs across many repos:

- **Check allowed merge methods** — repos may only allow rebase, squash, or merge commits. Use `gh api repos/OWNER/REPO --jq '{allow_merge: .allow_merge_commit, allow_rebase: .allow_rebase_merge, allow_squash: .allow_squash_merge}'`
- **`--admin` bypasses branch protection** — useful when `enforce_admins` is false and you're a repo admin
- **`--delete-branch` fails with merge queues** — omit the flag for repos with merge queues enabled
- **`dismiss_stale_reviews` clears approvals on force-push** — after rebasing, auto-approve workflows must re-run
- **GitHub API content pushes aren't GPG-signed** — commits via the Contents API use GitHub's web-flow committer

## Why Not Just Use `tailor set-version`?

Some tools (like TYPO3's `tailor`) can set the version at publish time. However:

- **Fail-fast is better** — catching mismatches early (pre-push or CI start) is cheaper than failing mid-publish
- **Consistency** — the repository should always reflect the correct version at the tagged commit
- **Auditability** — `git show v1.2.3:ext_emconf.php` should show the matching version
