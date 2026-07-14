# Publishing a generated site to GitHub Pages (and org-data collectors)

Lessons from shipping a nightly workflow that inventories an organization's repos and publishes a generated dashboard to GitHub Pages. Two classes of failure that a `200 OK` and a green build both hide.

## Hidden rate limits break the workflow and the deploy

A workflow that walks an org (per-repo file probes + issue/PR counts) exhausts limits that are separate from the familiar 5,000/hour user quota:

- **`GITHUB_TOKEN` installation limit — ~1,000 requests/hour, scoped to the repository the workflow runs in** (where the token is issued — *not* a separate quota per target repo you query). This is the token Actions injects, *distinct* from a PAT's 5,000/hr user limit. A collector that spends ~15 `GET /repos/{repo}/contents/{path}` probes per repo across ~100 target repos burns ~1,500 calls against that single budget and exhausts it — after which the **`deploy-pages` step 403s** ("API rate limit exceeded for installation") even though it makes one call. The build job starves the deploy job because they share the one installation quota.
- **Search API primary limit — 30 requests/minute (authenticated).** `GET /search/issues` for open-issue/PR/stale counts hits this within the first minute across a large org, and rate-limited responses come back as **403 that looks like "no data"** — counts silently become `null`/0 and the dashboard shows wrong numbers with a green build.

### Fixes

- **File presence: one `git/trees` call per repo, not N `contents` probes.** `GET /repos/{owner}/{repo}/git/trees/{ref}?recursive=1` returns the whole file listing in one request; test for `README`/`CODEOWNERS`/`SECURITY`/etc. against that set. ~3 calls/repo instead of ~15.
- **Counts: GraphQL, not the Search API.** One GraphQL sweep over `organization.repositories` returning `issues(states:OPEN){totalCount}` and `pullRequests(states:OPEN){totalCount}` is accurate for every repo and spends a handful of the 5,000-point/hour GraphQL budget. For stale-PR counts use `pullRequests(states:OPEN, first:100, orderBy:{field:UPDATED_AT, direction:ASC}){nodes{updatedAt}}` — `orderBy` takes an `IssueOrder` **object** (`{field,direction}`), not a bare enum; ASC lets you stop once past the cutoff, and you must paginate (or cap and flag) for repos with >100 open PRs or the count is silently low.
- **Retry only what's transient.** Retry 5xx and secondary-rate-limit responses (they carry `Retry-After`); let the primary Search limit fast-degrade to `null` rather than blocking. One flaky response should not abort a run whose output is written only at the end.
- **Budget the run.** Keep a full collection under ~1,000 REST calls so the shared installation token survives the `deploy-pages` job in the same workflow.

## Not every 403 is a rate limit — classify before reacting

A collector meets three different 403s, and they need opposite responses. Read the headers rather than the status code:

| 403 | Signal | Response |
|---|---|---|
| Primary rate limit | `x-ratelimit-remaining: 0` | Transient. Back off or degrade. |
| Secondary rate limit | `retry-after` present, *or* only the body says `"secondary rate limit"` | Transient. Honour `retry-after`. |
| Permission | Neither of the above; body names the cause (`Resource not accessible by integration`) | **Not** transient. Retrying burns the run and hides the cause. |

The secondary limit is the trap: it does **not** zero `x-ratelimit-remaining`, so `remaining == 0` alone misfiles it as a permission error and aborts a run that should have waited. And `retry-after` is sufficient but not necessary — [the docs](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api) only say it *may* be present — so the body is the last resort:

```python
def is_rate_limited(response):
    if response.headers.get("X-RateLimit-Remaining") == "0":
        return True
    if "Retry-After" in response.headers:
        return True
    return "secondary rate limit" in response.text.lower()
```

**Diagnostic: a sibling endpoint that still works disproves a rate limit in one step.** A budget is token-wide, so it cannot spare one endpoint and starve another. When `/stargazers` 403s on all 278 repos but `/forks` never fails once, on the same token in the same run, the cause is per-endpoint permission — no header reading required.

### Stargazers and subscribers are admin/collaborator-only (since 2026-06-30)

[GitHub restricted](https://github.blog/changelog/2026-06-30-upcoming-access-restrictions-to-public-api-endpoints-and-ui-views/) `GET /repos/{o}/{r}/stargazers` and `GET /repos/{o}/{r}/subscribers` to each repo's admins and collaborators — they were being scraped to harvest user data. `GET /users/{u}/subscriptions` is deprecated and returns empty. The UI views `/stargazers`, `/stargazers/you_know` and `/watchers` are restricted too; `/network/dependents` is not.

- **The Actions `GITHUB_TOKEN` is neither an admin nor a collaborator**, so it 403s on *every* repo — including the one the workflow runs in, with `Metadata: read` granted. `/forks` is unaffected.
- **Fix: a fine-grained PAT** whose owner is a collaborator. Both endpoints need only [Metadata: read](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens), which every fine-grained PAT carries by default — no extra permission to tick, and nothing under "Organization permissions".
- **Scope the PAT to *All repositories*, not a hand-picked list** (org policy permitting). A collector walks the org from `GET /orgs/{org}/repos`, so a select-repository PAT keeps discovering repos it may not read: every repo created after the PAT was minted degrades to a permission 403 and, in a collector that swallows per-item errors, disappears from the output with no signal. The failure grows silently as the org does.
- **The status code differs by token type:** an Actions token gets `403`; a user PAT gets **`404`** on repos where it is not a collaborator (GitHub hides existence rather than admitting the block). Don't read that 404 as "repo gone".
- A PAT expires. Make the run fail loudly and name the secret, or the collector silently reverts to reporting no news.

## A systemic error must abort; only per-item errors may degrade

"Retry only what's transient" (above) has a corollary: a collector that catches every error per repo, keeps the last known state and exits `0` reports **"0 new"** — indistinguishable from a genuine quiet period. A star-notification collector hid a total outage this way for 9+ days across ~900 runs; nobody was watching a green check that said `Found: 0 star(s)`.

- **Auth failures (401/403-permission) are systemic, never per-item.** Raise a distinct exception that the per-item handler cannot catch, so the job goes red with an actionable annotation:
  ```python
  class AuthError(Exception): ...          # not a RequestException
  ...
  except requests.exceptions.RequestException:   # per-repo, may degrade
      return None
  ```
- **Read the token with a default, and check it.** `os.environ["TOKEN"]` raises `KeyError` before any handler is installed; worse, Actions sets a *missing* secret to the **empty string**, so the variable exists and the failure is a silent 401. `os.environ.get("TOKEN", "")` plus an explicit emptiness check catches both.
- **A green run proves nothing on its own — assert on the failure count.** `Found: 0 star(s)` with 0 failed fetches is real; with 556 failed fetches it is an outage.

### Cross-run state: `dawidd6/action-download-artifact` matches any branch

Collectors persist state between runs by uploading an artifact and pulling it back with `dawidd6/action-download-artifact`. Its `branch` input has **no default**, so it takes the latest successful run of the workflow on *any* branch. A `workflow_dispatch` test on a feature branch therefore loads (and its upload then becomes) production state. Convenient for testing a fix against real data; set `branch:` explicitly if you need isolation.

## A Pages "200 OK" is not proof the page rendered

For a **JS-rendered** page (data embedded in the HTML, DOM built client-side), `curl` returning `200` with the correct `<title>` proves nothing — the body can be blank. Real incident: a `String.prototype.replace(placeholder, json)` bug (replaces only the first of two identical tokens) shipped `window.{…json…} = __PLACEHOLDER__;` — a syntax error, blank dashboard, green build, 200 response.

- **Verify by rendering, not by status.** Render headless and assert DOM population (a KPI value, a table row), e.g. `google-chrome --headless --dump-dom --virtual-time-budget=5000 <url>` then grep the post-JS DOM; or drive one interaction with Playwright and assert zero console errors.
- **Don't read deploy success from a Pages endpoint 404.** There is no `GET /repos/{o}/{r}/pages/deployments` list endpoint (it 404s); list deployments via `GET /repos/{o}/{r}/deployments`, or just trust the `deploy` job's own conclusion.

## Verify a workflow edit actually landed before claiming it

A silent editor failure (edit reported an error, never retried) left GitHub Actions pinned to old `@v4`/`@v3` majors while the summary claimed "SHA-pinned." The **CI annotation** (`Node.js 20 is deprecated…`) exposed it — the pass/fail status did not.

- After editing action versions/pins, read the run's **annotations** and the committed workflow file — do not claim "pinned/updated" from a green check alone. See the "CI Annotations" section in `references/security-config.md`.
