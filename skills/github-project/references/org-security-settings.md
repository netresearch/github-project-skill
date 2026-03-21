# Organization Security Settings Reference

Org-level GitHub security settings for Actions permissions, SHA pinning, and action allow-lists.

## SHA Pinning Requirement (`sha_pinning_required`)

Forces all GitHub Actions in the organization to use full SHA references instead of tags or branches.

### Key behavior

- **Enforced:** All `uses:` directives must reference actions by full commit SHA (e.g., `actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd`)
- **Exempt:** Reusable workflows called with `@main` or `@vX.Y.Z` are exempt -- they can still use branch/tag refs
- **Scope:** Applies to all repositories in the organization

### Enable via API

```bash
gh api orgs/ORG/actions/permissions -X PUT -F sha_pinning_required=true
```

### Verify current setting

```bash
gh api orgs/ORG/actions/permissions --jq '.sha_pinning_required'
```

## `pin-github-action` Tool

CLI tool to automatically convert tag-based action references to SHA-pinned references.

### Install and run

```bash
# Pin all workflows in a repo
npx pin-github-action@latest .github/workflows/*.yml

# Exclude internal org refs (keeps reusable workflow @main/@tag refs)
npx pin-github-action@latest .github/workflows/*.yml --allow "myorg/*"

# Continue on resolution errors (useful for batch operations)
npx pin-github-action@latest .github/workflows/*.yml --continue-on-error

# Use authenticated requests for higher rate limits
GITHUB_TOKEN=$(gh auth token) npx pin-github-action@latest .github/workflows/*.yml
```

### Batch script pattern for an entire org

```bash
#!/usr/bin/env bash
set -euo pipefail

ORG="myorg"
REPOS=$(gh repo list "$ORG" --no-archived --json nameWithOwner -q '.[].nameWithOwner')

for REPO in $REPOS; do
    echo "Processing $REPO..."
    TMPDIR=$(mktemp -d)
    if ! gh repo clone "$REPO" "$TMPDIR" -- --depth 1; then
        echo "Error: Failed to clone $REPO. Skipping." >&2
        rm -rf "$TMPDIR"
        continue
    fi

    WORKFLOWS=("$TMPDIR/.github/workflows/"*.yml)
    [[ -e "${WORKFLOWS[0]}" ]] || { rm -rf "$TMPDIR"; continue; }

    GITHUB_TOKEN=$(gh auth token) npx pin-github-action@latest "${WORKFLOWS[@]}" \
        --allow "$ORG/*" --continue-on-error

    cd "$TMPDIR"
    if ! git diff --quiet .github/workflows/; then
        git checkout -b chore/pin-actions
        git add .github/workflows/
        git commit -S --signoff -m "fix: SHA-pin GitHub Actions"
        git push -u origin chore/pin-actions
        gh pr create --title "fix: SHA-pin GitHub Actions" \
            --body "Pin all third-party GitHub Actions to full SHA refs for supply-chain security."
    fi
    cd -
    rm -rf "$TMPDIR"
done
```

## Allowed Actions Policy (`allowed_actions`)

Controls which actions can be used across the organization.

| Value | Effect |
|-------|--------|
| `all` | Any action can be used (no restrictions) |
| `local_only` | Only actions defined in the same repository |
| `selected` | Only actions matching the allow-list |

### Configure via API

```bash
# Set to selected (most secure)
gh api orgs/ORG/actions/permissions -X PUT \
    -f allowed_actions=selected

# View current policy
gh api orgs/ORG/actions/permissions --jq '.allowed_actions'
```

## Action Allow-Lists

When `allowed_actions` is `selected`, configure which actions are permitted.

### View current allow-list

```bash
gh api orgs/ORG/actions/permissions/selected-actions --jq '{
    github_owned_actions_allowed: .github_owned_actions_allowed,
    verified_allowed: .verified_allowed,
    patterns_allowed: .patterns_allowed
}'
```

### Update allow-list

```bash
gh api orgs/ORG/actions/permissions/selected-actions -X PUT --input - <<'EOF'
{
    "github_owned_actions_allowed": true,
    "verified_allowed": true,
    "patterns_allowed": [
        "slsa-framework/*",
        "sigstore/*",
        "reviewdog/*",
        "myorg/*"
    ]
}
EOF
```

### Fields

| Field | Description |
|-------|-------------|
| `github_owned_actions_allowed` | Allow all `actions/*` and `github/*` actions |
| `verified_allowed` | Allow actions from verified marketplace creators |
| `patterns_allowed` | List of glob patterns for additional allowed actions |

> **Important:** Composite actions' internal sub-actions must also be in the allow-list. See [`security-config.md`](./security-config.md#composite-action-sub-action-allow-list-gotcha) for the Composite Action Sub-Action Allow-List Gotcha.
