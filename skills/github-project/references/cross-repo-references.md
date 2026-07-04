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
