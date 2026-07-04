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

## A Pages "200 OK" is not proof the page rendered

For a **JS-rendered** page (data embedded in the HTML, DOM built client-side), `curl` returning `200` with the correct `<title>` proves nothing — the body can be blank. Real incident: a `String.prototype.replace(placeholder, json)` bug (replaces only the first of two identical tokens) shipped `window.{…json…} = __PLACEHOLDER__;` — a syntax error, blank dashboard, green build, 200 response.

- **Verify by rendering, not by status.** Render headless and assert DOM population (a KPI value, a table row), e.g. `google-chrome --headless --dump-dom --virtual-time-budget=5000 <url>` then grep the post-JS DOM; or drive one interaction with Playwright and assert zero console errors.
- **Don't read deploy success from a Pages endpoint 404.** There is no `GET /repos/{o}/{r}/pages/deployments` list endpoint (it 404s); list deployments via `GET /repos/{o}/{r}/deployments`, or just trust the `deploy` job's own conclusion.

## Verify a workflow edit actually landed before claiming it

A silent editor failure (edit reported an error, never retried) left GitHub Actions pinned to old `@v4`/`@v3` majors while the summary claimed "SHA-pinned." The **CI annotation** (`Node.js 20 is deprecated…`) exposed it — the pass/fail status did not.

- After editing action versions/pins, read the run's **annotations** and the committed workflow file — do not claim "pinned/updated" from a green check alone. See the "CI Annotations" section in `references/security-config.md`.
