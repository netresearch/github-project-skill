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

# Find semver tags at HEAD (adjust pattern for v-prefixed tags if needed)
TAGS=$(git tag --points-at HEAD | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' || true)
[[ -z "${TAGS}" ]] && exit 0

# Extract version from your version file (adapt grep pattern per project)
FILE_VERSION=$(grep -oP "'version'\s*=>\s*'\K[^']+" version-file.ext)

while IFS= read -r TAG; do
    TAG_VERSION="${TAG#v}"  # Strip optional v prefix
    if [[ "${TAG_VERSION}" != "${FILE_VERSION}" ]]; then
        echo "ERROR: Tag ${TAG} does not match version file (${FILE_VERSION})"
        exit 1
    fi
done <<< "${TAGS}"
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
    FILE_VERSION=$(grep -oP "'version'\s*=>\s*'\K[^']+" version-file.ext)
    if [[ "${TAG_VERSION}" != "${FILE_VERSION}" ]]; then
      echo "::error file=version-file.ext::Tag (${TAG_VERSION}) does not match version file (${FILE_VERSION})"
      exit 1
    fi
    echo "Version validated: ${TAG_VERSION}"
```

## Common Version File Patterns

| Ecosystem | File | Extraction |
|-----------|------|------------|
| TYPO3 | `ext_emconf.php` | `grep -oP "'version'\s*=>\s*'\K[^']+"` |
| Node.js | `package.json` | `jq -r .version` |
| Python | `pyproject.toml` | `grep -oP '^version\s*=\s*"\K[^"]+'` |
| Go | `version.go` | `grep -oP 'Version\s*=\s*"\K[^"]+'` |
| Rust | `Cargo.toml` | `grep -oP '^version\s*=\s*"\K[^"]+'` |

## Why Not Just Use `tailor set-version`?

Some tools (like TYPO3's `tailor`) can set the version at publish time. However:

- **Fail-fast is better** — catching mismatches early (pre-push or CI start) is cheaper than failing mid-publish
- **Consistency** — the repository should always reflect the correct version at the tagged commit
- **Auditability** — `git show v1.2.3:ext_emconf.php` should show the matching version
