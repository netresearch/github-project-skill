# Tag-Version Validation Reference

**Purpose:** Document patterns for validating that version tags match in-repo version files, working around GitHub.com's lack of server-side pre-receive hooks.

## The Problem

GitHub.com (cloud) does not support custom **pre-receive hooks** — those are only available on GitHub Enterprise Server. This means you cannot reject a tag push server-side based on custom validation logic (e.g., checking that a tag matches a version file).

## Defense-in-Depth Pattern

Use three layers of protection:

1. **Local git hook** (pre-push) — catches mistakes before they leave the developer's machine
2. **CI lint validation** — catches anything that slips through (force-push, web UI tag creation, etc.)
3. **Release workflow validation** — final gate before packaging/publishing

```
Developer                     GitHub
    │                            │
    ├─ bump version file         │
    ├─ git commit -S             │
    ├─ git tag -s v1.2.3         │
    ├─ git push --tags           │
    │   └─ pre-push hook ─ FAIL  │  ← Layer 1: Local gate
    │      "version mismatch"    │
    │                            │
    ├─ fix version, amend, push  │
    │   └─ pre-push hook ─ PASS ─┼─► tag pushed
    │                            │
    │                            ├─ Lint workflow (tag trigger)
    │                            ├─ Validate version ─ PASS  ← Layer 2: CI safety net
    │                            │
    │                            ├─ Release workflow (tag trigger)
    │                            ├─ Validate version ─ PASS  ← Layer 3: Release gate
    │                            └─ Package & publish
```

### Critical: Never Bump Versions in Release Workflows

The release workflow must **only validate**, never bump version files:

- The signed tag already points at a specific commit
- Bumping the version file after tagging creates a **new commit** that the tag does NOT point to
- The tag would then reference a commit with the wrong version — defeating the purpose
- Correct flow: bump version → commit → sign tag → push → release validates and packages

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

### Hook Installation Methods

#### direnv + `core.hooksPath` (no dependencies)

For repos without Node.js or PHP tooling. Uses `Build/hooks/` directory with direnv auto-setup:

**`Build/hooks/pre-push`:**

```bash
#!/usr/bin/env bash
"$(dirname "$0")/../Scripts/check-plugin-version.sh"
```

**`.envrc`:**

```bash
# Install git hooks for version validation
git config core.hooksPath Build/hooks
```

Developers run `direnv allow` once — hooks are active automatically on every `cd` into the project.

#### CaptainHook (PHP projects)

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

#### Husky (Node.js projects)

**`.husky/pre-push`:**

```bash
#!/usr/bin/env sh
Build/Scripts/check-tag-version.sh
```

## CI Lint Validation Step (GitHub Actions)

Add to `lint.yml` with `tags: ['v*']` trigger. Runs on every tag push as a safety net:

```yaml
  version:
    name: Plugin Version
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Validate version file matches tag
        run: |
          # Adapt extraction per ecosystem (see table below)
          FILE_VERSION=$(sed -nE "s/.*'version'[[:space:]]*=>[[:space:]]*'([^']+)'.*/\1/p" version-file.ext)
          if [[ -z "${FILE_VERSION}" ]]; then
            echo "::error file=version-file.ext::Could not extract version from version-file.ext"
            exit 1
          fi
          # On tag push, verify tag matches version file
          if [[ "$GITHUB_REF" == refs/tags/v* ]]; then
            TAG_VERSION="${GITHUB_REF#refs/tags/v}"
            if [[ "${TAG_VERSION}" != "${FILE_VERSION}" ]]; then
              echo "::error file=version-file.ext::Tag v${TAG_VERSION} does not match version file ${FILE_VERSION}"
              exit 1
            fi
            echo "Version match confirmed: v${TAG_VERSION}"
          else
            # Non-tag push: just validate format
            echo "Version format valid: ${FILE_VERSION}"
          fi
```

## Release Workflow Validation (GitHub Actions)

Add **before** any packaging/publish step in the release workflow. This is the final gate — validation only:

```yaml
      - name: Validate version file matches tag
        env:
          TAG_VERSION: ${{ github.ref_name }}
        run: |
          # Adapt extraction command per ecosystem (see table below)
          FILE_VERSION=$(python3 -c "import json; print(json.load(open('.claude-plugin/plugin.json'))['version'])")
          TAG_BARE="${TAG_VERSION#v}"
          if [[ "${TAG_BARE}" != "${FILE_VERSION}" ]]; then
            echo "::error file=.claude-plugin/plugin.json::Tag ${TAG_VERSION} does not match version file ${FILE_VERSION}"
            exit 1
          fi
          echo "Version validated: ${TAG_VERSION} matches ${FILE_VERSION}"
```

**Important:** Use `env:` to pass `github.ref_name` — never interpolate `${{ }}` directly in `run:` blocks (script injection risk).

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

- **Check allowed merge methods** — repos may only allow rebase, squash, or merge commits. Use `gh api repos/OWNER/REPO --jq '{allow_merge: .allow_merge_commit, allow_rebase: .allow_rebase_merge, allow_squash: .allow_squash_merge}'`. Detection snippet + the rebase-merge-cannot-be-signed caveat are in [`auto-merge-guide.md`](./auto-merge-guide.md) → "Signed Commits and Merge Strategy Compatibility". Real-world heterogeneity to expect: across one Netresearch fleet alone, some repos allow only rebase, some only merge commits, and some all three.
- **`--admin` bypasses branch protection** — useful when `enforce_admins` is false and you're a repo admin
- **`dismiss_stale_reviews` clears approvals on force-push** — after rebasing, prior approvals are dismissed and any auto-approve workflow must re-run. This is expected behavior, not a bug. See [`auto-merge-guide.md`](./auto-merge-guide.md) → "Auto-Approve Race Condition with Copilot Reviewer" for the variant where auto-approve fires before Copilot finishes reviewing and the PR ends up `REVIEW_REQUIRED` blocked.

### `gh pr merge --delete-branch` fails with merge queues

Repos with merge queues enabled reject the `-d` / `--delete-branch` flag — the queue manages the head-branch lifecycle itself. Symptom: `gh pr merge` exits non-zero with an error mentioning the merge queue, even though the PR was added to the queue successfully.

**Fix — detect the queue first, then conditionally drop the flag.** Note: `gh api "repos/$REPO"` does NOT return a `merge_queue` field; query GraphQL `Repository.mergeQueue` instead, which returns `null` when no queue is configured:

```bash
OWNER="${REPO%/*}"; NAME="${REPO#*/}"
has_queue=$(gh api graphql -f query="{ repository(owner: \"$OWNER\", name: \"$NAME\") { mergeQueue { id } } }" \
  --jq '.data.repository.mergeQueue // "null"')
if [[ "$?" -ne 0 ]]; then
  echo "Error: failed to query merge queue status for $REPO" >&2
  exit 1
fi
# Auto-detect allowed merge strategy too — repos may not allow `--merge`.
# See auto-merge-guide.md → "Signed Commits and Merge Strategy Compatibility".
STRATEGY=$(gh api "repos/$REPO" --jq '
  if .allow_squash_merge then "--squash"
  elif .allow_merge_commit then "--merge"
  elif .allow_rebase_merge then "--rebase"
  else "--squash" end')

if [[ "$has_queue" == "null" ]]; then
  gh pr merge "$PR" --repo "$REPO" "$STRATEGY" --delete-branch
else
  gh pr merge "$PR" --repo "$REPO" "$STRATEGY"   # queue handles branch deletion
fi
```

In a batch loop across mixed repos, always run **both** detections per repo — assuming "no queue" silently leaves stale branches behind on the queue-enabled ones, assuming "queue" causes `--delete-branch` failures on the unqueued ones, and hardcoding `--merge` causes "merge method not allowed" failures on repos that only permit squash or rebase.

### Contents API commits don't satisfy `required_signatures`

`gh api -X PUT repos/.../contents/...` is the fastest way to land a one-line edit across many repos, but the resulting commits use GitHub's `web-flow` committer identity — they are **not signed with your GPG/SSH key**. On any repo with branch protection `required_signatures: true`, those commits are rejected by the merge gate.

**Symptom:** the API push itself succeeds (HTTP 201), but a follow-up PR or the same-branch merge fails with:

```
Required signatures: At least one of the commits is not signed.
```

Or, on default-branch direct pushes, HTTP 409 from the contents API itself when branch protection blocks unsigned commits.

**Workarounds (pick the one that matches your situation):**

1. **`gh pr merge --admin`** — bypass branch protection on a per-merge basis. Requires `enforce_admins: false` AND admin role on the repo. Cleanest for solo-maintainer batch ops.
2. **Push real local commits via SSH** instead of using the contents API. Slightly slower per repo, but the commits carry your signature and need no bypass. This is the safer default when the batch mixes signing-required and signing-optional repos — it works uniformly.
3. **GitHub App with verified signing** — if the batch tool is something other people will run too, register a GitHub App with a verified signing identity and have it commit on your behalf. Heavier setup, but no per-repo admin bypass and no per-user keys.

See also [`multi-repo-operations.md`](./multi-repo-operations.md) → "Contents API vs branch protection" for the related HTTP 409 angle (PR-required / merge-queue-required repos rejecting contents API pushes regardless of signing).

## Why Not Just Use `tailor set-version`?

Some tools (like TYPO3's `tailor`) can set the version at publish time. However:

- **Fail-fast is better** — catching mismatches early (pre-push or CI start) is cheaper than failing mid-publish
- **Consistency** — the repository should always reflect the correct version at the tagged commit
- **Auditability** — `git show v1.2.3:ext_emconf.php` should show the matching version
