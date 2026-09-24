# Retiring a Repository

A repository nobody consumes is retired, not upgraded. Measure the consumers
**before** the first upgrade step — the result decides which of the two
tasks you are doing. (Observed 2026-09-24 on `netresearch/deploy-rst`: the
default-branch rename, three rulesets and a template-sync PR were all done
before the consumer count — 29 downloads in total, 0 per month, 0
dependents — turned the task into an archive.)

## 1. Measure the consumers

```bash
# Packagist: downloads and dependent packages (Composer packages)
curl -s "https://packagist.org/packages/VENDOR/NAME.json" \
  | jq '{downloads: .package.downloads, dependents: .package.dependents}'

# Org-internal references — REST search, not `gh search code`
# (see multi-repo-operations.md § "Never enumerate by content with gh search code")
gh api --paginate "search/code?q=%22VENDOR/NAME%22+org:OWNER&per_page=100" \
  --jq '.items[] | "\(.repository.name)|\(.path)"' | sort -u
```

A hit list that contains only the repository itself is the known-positive
baseline: the index covers the repository, and nothing else references it.
An empty list proves nothing — the search may simply have failed.

Check the runtime premise too: a tool whose integration target is gone (for
example a SOAP client for a server product the organisation replaced with
the cloud edition) has no users to find, whatever the numbers say.

## 2. Mark the package as abandoned

For a Composer package, add the flag to `composer.json` on the default
branch:

```json
"abandoned": true
```

(or `"abandoned": "vendor/replacement"` to name a successor). Packagist
reads the flag from the default branch and marks the **whole package**
abandoned, including tagged versions that predate the change — no Packagist
login and no "Abandon" button needed.

Add a notice at the top of the README. In an `.rst` README use bold text
between `----` transitions — GitHub renders RST admonitions as plain text
(see `repository-structure.md`).

## 3. Merge, then let CI settle

Merge the change, then wait until every workflow run on the merge commit
has completed and passed. Pin the SHA, so a run for an older commit cannot
stand in for the last one; the archived repository then ends on a known
green state.

```bash
SHA=$(git rev-parse origin/main)
gh run list -R OWNER/REPO --commit "$SHA" \
  --json name,status,conclusion --jq '.[] | "\(.name): \(.status)/\(.conclusion)"'
```

## 4. Archive

```bash
gh repo archive OWNER/REPO --yes
gh api repos/OWNER/REPO --jq .archived     # true
```

## 5. Verify the registry — past its cache

`packagist.org/packages/VENDOR/NAME.json` is served from a cache and can
report `"abandoned": null` for several minutes after the update. The
Composer v2 metadata reflects the change first:

```bash
curl -s "https://repo.packagist.org/p2/VENDOR/NAME~dev.json" \
  | jq '[.packages["VENDOR/NAME"][] | {version, abandoned}]'
curl -s "https://packagist.org/packages/VENDOR/NAME.json?nocache=$(date +%s)" \
  | jq '.package.abandoned'
```

A `null` on the first read is a cache hit, not a missing flag — re-read
with the cache-buster before telling anyone to click anything.
