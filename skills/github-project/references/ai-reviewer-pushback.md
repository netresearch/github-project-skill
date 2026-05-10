# AI Reviewer Pushback Patterns

How to evaluate, respond to, and resolve review comments from automated AI reviewers (GitHub Copilot, gemini-code-assist, CodeRabbit, Sourcery, Codium / PR-Agent, etc.) without either rubber-stamping wrong advice or ignoring valid feedback.

## When to use

- An AI reviewer left comments on a PR and you need to decide which to apply.
- A reviewer flagged a "high priority" issue that contradicts your local verification.
- You're being asked to change config, code, or APIs based on AI-generated suggestions.

## The core problem

AI code reviewers produce a mix of:

1. **Genuinely useful catches** — typos, missing null checks, leaked secrets, unused imports, accessibility issues, the kind of thing a careful reviewer would also notice.
2. **Stylistic preferences** — usually low-stakes, often defensible either way.
3. **Plausible-sounding but factually wrong claims** — invented API names, deprecated patterns presented as current, version-status claims that lag reality.

Categories 1 and 2 are easy. Category 3 is the dangerous one: an AI reviewer states with full confidence that "the field is named X" or "this version is not yet released," and a hurried maintainer applies the change to clear the review. The fix breaks the build, regresses security, or introduces a real bug.

## Common failure modes to watch for

### Field-name / API-name hallucination

The reviewer asserts that a config key, function, or type is named X. The name doesn't exist in current docs (or never existed at all).

**Real examples seen in the wild:**

- gemini-code-assist suggested `ignoredBuilds:` for pnpm 11. Pnpm 11 has no `ignoredBuilds` setting — the legacy field was named `ignoredBuiltDependencies` (deprecated 10.26, removed in 11), and the modern equivalent is `allowBuilds: { pkg: false }`.
- Suggesting `secrets: inherit` "for simplicity" in reusable workflows — actively dangerous, exposes the entire org-secret namespace.
- Recommending TYPO3 v11 ViewHelper namespaces in v13/v14 code.

**Tell:** the suggestion always sounds confident, often quotes a documentation-shaped block, and doesn't link to the docs.

### Stale knowledge of release status

The reviewer claims a current release "is not out yet," recommends an outdated minimum version, or asserts a feature "doesn't exist" when it has shipped. Training cutoffs are months to years behind, and bots rarely declare their knowledge boundary.

**Illustrative shapes** (specific versions cited here will go stale — treat as examples of the pattern, not authoritative current state):

- "Language X version N is not released yet" — when it is. Verify against the language's release page.
- "Use Node N as the maximum supported version" — when a newer LTS is current.
- "Framework F version N has not been released" — when an N.x release is already in production.

**Tell:** version assertions without a release-date check, or recommendations that pull constraints downward from what your CI matrix is already running.

### Pattern advice frozen at a past major

The reviewer suggests a deprecated pattern that was current in their training data: jQuery for vanilla DOM tasks, Vue 2 Options API in a Vue 3 codebase, deprecated GitHub Actions inputs (`fail_on_error` instead of `fail_level`), CKEditor 4 plugin shapes used in a CKEditor 5 codebase.

**Tell:** the advice contradicts code patterns already in the same file or neighbouring files.

### Inverting a security control

The reviewer recommends weakening a control "to fix the failing build." The build is failing because the control is correctly enforcing a new default; the right fix is configuration, not weakening.

**Real examples:**

- "Set `strict-peer-dependencies=false`" when the underlying issue is a missing peer.
- "Set `engine-strict=false`" when engines is correctly rejecting an unsupported version.
- "Disable harden-runner" when an egress is being legitimately blocked.

**Tell:** the suggested change makes the symptom go away by removing the check that produced the symptom.

## The pushback workflow

When you suspect a reviewer comment is wrong, follow this sequence **before** changing any code:

### 1. Verify against primary sources

Open the official docs for the library/tool the reviewer is talking about. Look for:

- The exact field/API name they suggested. Is it in the current docs? Was it ever in the docs?
- The version they reference. Is that the current major? Was the feature/deprecation they mention introduced/removed in a release that has already shipped?
- The release-status claim. Cross-check against the project's release page or registry.

If you have a documentation lookup tool available (e.g. the [Context7](https://github.com/upstash/context7) MCP server, which fetches current library docs on demand), use it. Otherwise fetch the docs URL directly. Treat AI training-data as a stale snapshot.

### 2. Check empirical evidence already on the PR

If the reviewer is claiming "this won't work" but **CI is green**, that's strong evidence the configuration does work. Note:

- The specific check name (e.g. `build-and-push`).
- The conclusion (`SUCCESS`).
- The pnpm/node/php/library version the runner used (often visible in the install-step log).

A green CI run on a non-trivial check is empirical evidence that overrides a confident textual assertion. Cite it.

### 3. Read the bot's "why"

Some bots include a rationale block. If the rationale references behavior from a deprecated version, an old release line, or a feature that was removed, that's diagnostic. Quote it back when you reply.

### 4. Decide

Three legitimate outcomes:

1. **Apply the change.** The reviewer is right. Make the change in a follow-up commit and reply linking the commit SHA.
2. **Push back.** The reviewer is wrong. Reply on the thread with citations and resolve. Do NOT change the code.
3. **Compromise.** The reviewer has a point but the suggested implementation is wrong. Reply explaining the alternative, link the commit that does the right thing.

### 5. Reply directly to the thread

Always reply to the review-comment thread, not as a top-level PR comment. The reply preserves context and lets future readers follow the disagreement.

```bash
# Find thread IDs
gh api graphql -f query='query {
  repository(owner: "OWNER", name: "REPO") {
    pullRequest(number: NUMBER) {
      reviewThreads(first: 50) {
        nodes {
          id
          isResolved
          comments(first: 1) {
            nodes { databaseId author { login } body }
          }
        }
      }
    }
  }
}' --jq '.data.repository.pullRequest.reviewThreads.nodes[] |
  {id, isResolved,
   author: .comments.nodes[0]?.author?.login,
   snippet: (.comments.nodes[0]?.body // "")[0:100]}'

# Reply to a thread
gh api graphql \
  -f query='mutation($body: String!, $tid: ID!) {
    addPullRequestReviewThreadReply(input: {body: $body, pullRequestReviewThreadId: $tid}) {
      comment { url }
    }
  }' \
  -f tid="PRRT_xxx" \
  -f body="See pnpm 10.26 release notes (https://...) — the field is named allowBuilds and takes a map, not an array."
```

### 6. Resolve the thread

After replying, resolve. Don't leave threads open as a passive-aggressive disagreement marker — it makes the PR look unsettled to future reviewers and can block merges on repos that require thread resolution.

```bash
gh api graphql \
  -f query='mutation($tid: ID!) {
    resolveReviewThread(input: {threadId: $tid}) {
      thread { isResolved }
    }
  }' \
  -f tid="PRRT_xxx"
```

## Reply template — pushback with evidence

A good pushback reply has four parts:

1. **State the disagreement** in one sentence.
2. **Cite the primary source** (link, with relevant quote).
3. **Cite empirical evidence** (CI run, test result, doc URL).
4. **State what you are doing** (leaving as-is / applying alt fix / etc.).

Example:

> Thanks, but this suggestion is incorrect on both points and I am leaving the config as-is.
>
> **1. The field is `allowBuilds` and it is a map.** [pnpm 10.26 release notes](https://pnpm.io/blog/releases/10.26) define it as a map of package matchers to booleans, supporting per-version pinning (`nx@21.6.4: true`).
>
> **2. `ignoredBuilds` is not a pnpm setting.** The legacy field was `ignoredBuiltDependencies`, also removed in pnpm 11.
>
> **3. Verified empirically.** The `build-and-push` CI check is green on this PR with the current config (pnpm v11.0.9), no `ERR_PNPM_IGNORED_BUILDS` warning.

This pattern works for any bot reviewer. Three citations + a clear decision.

## Reply template — partial agreement

When the reviewer raised a real concern but suggested a wrong fix:

> Good catch on the underlying issue — fixed in [<commit-sha>](<commit-url>).
>
> Going with `<alternative>` rather than `<bot-suggestion>` because <one-sentence reason with link>.

## Anti-patterns

- **Silently making the change to clear the review.** Future maintainers can't tell whether the change was correct or compliance-driven.
- **Top-level "thanks, addressed in commit X" comments.** Lose the diff context. Always reply on the thread.
- **"Disagree, see commit history."** Not a reply. Cite docs and CI evidence.
- **Leaving the thread unresolved with no reply.** Reads as ignoring the bot. Reply, then resolve.
- **Marking a thread resolved without replying when you applied the change.** Drops the rationale; future readers see a closed thread with no record of the decision.

## Per-bot quirks

Behavior is bot-specific and changes; treat as starting hints, verify against current behavior:

| Bot | Note |
|-----|------|
| `gemini-code-assist[bot]` | Often confidently invents config field names; severity badges (`high`/`medium`) are not always correlated with actual severity |
| `copilot-pull-request-reviewer[bot]` | Tends toward verbose summaries; reviews almost never come back as `APPROVED` (state is `COMMENTED`); see `auto-merge-guide.md` for the auto-merge race condition |
| `coderabbitai[bot]` | Higher signal but verbose; prone to repeating the same nit across many threads — resolving in batches is reasonable |
| `sourcery-ai[bot]` | Stylistic / refactor focus; advice quality drops on non-mainstream language constructs |

## Related

- `auto-merge-guide.md` — Copilot-as-reviewer race condition that blocks PRs without leaving an actionable review
- `merge-strategy.md` — for repos that require all threads resolved before merge
