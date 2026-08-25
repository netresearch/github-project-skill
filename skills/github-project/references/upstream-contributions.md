# Contributing to Repositories You Do Not Own

First contribution to a foreign repo — an issue, a PR, or both. Every step here
exists because skipping it produced a public artifact that had to be walked
back.

## Before filing anything: read the lists, not just search results

Read the **open issue list AND the open PR list** before writing a word.
Keyword searches find your phrasing, not the problem: three searches
("dry-run exit", "changed_files", "xliff diff") all came back empty against a
repo whose issue #427 described the same defect as "don't return **error
code**" — and whose open PR #430 already fixed it. The repo had six open
issues; reading the list would have taken a minute. The duplicate issue and PR
both had to be closed with thanks.

```bash
gh issue list -R OWNER/REPO --state open   # read it, all of it if small
gh pr list -R OWNER/REPO --state open      # the fix may already be in flight
```

An empty keyword search is first a broken query, never evidence of absence.

## Read the contribution contract — and run ALL of it

`CONTRIBUTING.md` or the README's contributing section, every linked step, the
issue/PR templates, and the workflows under `.github/workflows/` (they encode
gates prose never mentions: linear-history checks, rebase-on-latest-main
requirements). Running four of five documented steps is not compliance — the
skipped `composer docs` step is the one the maintainer notices.

Conventions are read from artifacts, not assumed:

- **Commit style** from `git log --oneline -10` (e.g. `[BUGFIX]`/`[TASK]`
  prefixes vs conventional commits).
- **Sign-off** from recent commit trailers — a repo where 0 of the last 6
  commits carry `Signed-off-by` does not want yours enforced; carrying your own
  disclosure trailers is fine where nothing bans them.

## Match the code style you measure, not the style you brought

House style does not travel. Before writing code, measure the target:

```bash
# comment density and the longest comment block in their source
find src -name '*.php' | xargs grep -cE '^\s*//' | awk -F: '{s+=$2; n++} END {print s/n " avg comment lines/file"}'
```

A codebase whose largest existing comment block is two lines does not want
your six-line rationale inline — that context belongs in the commit message
and PR body, which is where such projects keep it. Two five-line comment
blocks were the longest in an entire codebase until a reviewer asked why.

## Open the PR as a draft

A first-time PR into a foreign org starts in draft. It signals "for your
judgment" rather than "merge me", costs one click to promote, and gives the
maintainers the first move. Converting later: `gh pr ready <n>`.

## Their fixers are not your diff

Project-level format/rectify gates may rewrite files you never touched (their
main simply drifted). Revert those before committing — a first PR that
reformats four unrelated files reads as carelessness:

```bash
git checkout -- <paths the fixer touched that you did not>
```

## When a maintainer asks "does X fix your problem?" — run X

Check out the competing branch and run it against **your own reproduction**,
then answer with the measured result. A table of before/after numbers settles
in one comment what diff-reading speculation cannot — and if the other fix is
better, say so plainly and close your own PR in its favour, with thanks.

## Closing your superseded work

Close with a reference to what supersedes it and what, if anything, of yours
remains useful (offer it as a follow-up, do not relitigate). The goodwill from
a clean retreat is worth more than the PR was.
