# Cross-Repo Issue/PR References in Markdown

GitHub autolinks a bare `#NN` in an issue/PR/comment body to an issue or PR **in
the same repository**. When the number belongs to a *different* repo, a bare
`#NN` silently links to the wrong target — it does not error, it renders as a
valid link pointing somewhere unintended.

## The trap

The failure is invisible in the source and only wrong at render time. It bites
hardest in a repo literally named `.github`, where a stray `#137` resolves to
`owner/.github#137` — usually an unrelated PR that happens to share the number.

```markdown
<!-- Written in owner/.github, meaning owner/other-repo#137 -->
root-caused via owner/other-repo#136 / #137
                                        ^^^^  links to owner/.github#137 — WRONG
```

Note that `owner/other-repo#136` is fine (it carries the repo), while the
adjacent bare `#137` is not — mixed forms in one sentence are a common source of
this bug.

## The rule

A cross-repo reference must carry the repo. Use one of:

```markdown
owner/repo#137                                   <!-- full autolink form -->
[#137](https://github.com/owner/repo/pull/137)   <!-- explicit markdown link -->
```

A bare `#137` is correct **only** when it targets the same repo the body lives
in. When in doubt, use the explicit markdown link — it is unambiguous and
survives the body being copied into another repo.

## Verifying before you post

Render the body through GitHub's GFM API and check where each reference actually
points, rather than eyeballing the source:

```bash
jq -Rs --arg ctx "owner/repo" '{text:., mode:"gfm", context:$ctx}' body.md \
  | gh api -X POST /markdown --input - \
  | grep -oE 'href="[^"]*/(pull|issues)/[0-9]+"'
```

Any `href` pointing at a repo you did not intend is a bare-reference bug — fix
it to `owner/repo#NN` or a markdown link. A quick pre-scan for the risky pattern
(a `#NN` not preceded by a repo name) narrows where to look:

```bash
grep -noE '[^/A-Za-z0-9_.-]#[0-9]+' body.md
```

## Referencing code: a permalink needs a commit SHA

Pointing at source in an issue, PR or review comment has the same failure mode
one level over: a link that looks right and does something else.

GitHub renders the **embedded code preview** — file, line range, syntax
highlighting, always matching what it points at — only for a URL that carries a
**commit SHA** and sits alone on its own line:

```markdown
https://github.com/owner/repo/blob/2a44dd1527a1f70da48d6b484bcb7a8849a6e5fb/src/File.php#L164-L173
```

A `/blob/<tag>/…` or `/blob/<branch>/…` link is **not** a permalink. It renders
as a bare link with no preview, and later resolves to different code, because
both refs move. In the browser, `y` rewrites the address to the permalink form.

**The preview has two limits worth knowing before you rely on it.** It renders
only in a **comment** — issue, PR, review — never in a Markdown file in the
repository. And it renders only where the comment lives in the **same
repository** as the linked code; a permalink into another repository stays a
plain URL. Cross-repo, the SHA still buys the thing that matters most — the link
keeps pointing at the code you meant — so use it there too, and write the
sentence so it reads without the preview.

Two consequences worth stating, because both cost a correction:

**Do not paste the code next to the link.** A rendered permalink already shows
the source. A copy beside it is duplication that goes stale, and an abbreviated
one (`...` in the middle) is strictly worse than the preview it replaces.

**Resolve the SHA, then re-check the line numbers against that SHA.** Line
numbers taken from a tag or a local checkout may not line up with the commit you
end up linking. A report whose snippet does not match its line numbers invites
exactly the question you least want — "was the file modified locally?" — and
upstream maintainers have closed reports on that basis.

```bash
repo=owner/repo; ref=v1.2.3; path=src/File.php
sha=$(gh api "repos/$repo/commits/$ref" --jq .sha)
gh api "repos/$repo/contents/$path?ref=$sha" --jq .content \
  | base64 -d | sed -n '164,173p'     # confirm the range before linking it
```

The placeholders are variables on purpose: written inline as `<tag-or-branch>`,
the shell reads `<` as a redirection and the command runs without the ref
instead of failing loudly.
