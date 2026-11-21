<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

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

**Read Discussions too, and do not read a bot-closed issue as a decision.** Where
a project routes feature requests to Discussions, the issue tracker takes bug
reports only and a bot closes everything else within the minute — `NOT_PLANNED`
there is triage, not a verdict, while the live thread sits open in Discussions
with the same title. herdrdev/herdr#2045 was closed that way; the same request
was open as discussion #2047 with no maintainer answer.

```bash
# search by keyword, not the newest N — a matching thread can be years old
gh api graphql -f q='repo:OWNER/REPO <keywords>' -f query='query($q:String!){search(query:$q,type:DISCUSSION,first:25){nodes{... on Discussion{number title closed url}}}}'
```

**Check whether the repo accepts pull requests from you at all — before writing
code.** Some projects gate contributions on an allowlist: `CONTRIBUTING.md` says
unsolicited pull requests are closed automatically, and only accounts listed in
a file such as `.github/APPROVED_CONTRIBUTORS` (or the maintainers file) may
open one. A finished patch then has no route in there. Follow whatever process the
repository documents for getting access — and where it documents none, or
forbids asking (herdr's `CONTRIBUTING.md` does), the remaining step is a comment
on the relevant discussion. Read those two files with the issue and PR lists,
and match them against the account `gh auth status` reports.

## File a report only for code that needs the fix

Before filing a bug report, name the code of ours that hits the bug. A
difference found by a comparison (two PHP versions, two library releases) is a
finding, not yet a report. If none of our code takes the affected path, the
report has no consumer. Tell the user that, warn that maintainers often close
such reports as not planned, and recommend not filing.

nikic/PHP-Parser#1188 reported that `PipeOperatorEmulator::reverseEmulate()`
does not re-lex a `=` or `>` after it splits a PHP 8.5 `T_PIPE`. The body
named no code of ours that reads the token stream, and it said that parse
results do not change. The maintainer quoted that sentence back, answered that
reverse emulation is best effort and that only reports from real-world need are
wanted, and closed the issue as not planned.

A report body names the code that the defect affects. A statement about output
that does not change ("parse results do not change") is accurate and can stay,
but only next to that consumer. If the body can name no consumer, the report
should not exist.

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

## Recognise a block by the repository owner

A repository owner can block an account. GitHub then refuses every comment
write from that account, but each surface words the refusal differently, and
only the first two name the block:

| Surface | Message |
| --- | --- |
| `gh issue comment` | `GraphQL: User is blocked (addComment)` |
| REST `POST /repos/OWNER/REPO/issues/N/comments` | `403 Blocked` |
| REST `PATCH /repos/OWNER/REPO/issues/comments/ID` on your own comment | `403 Must have admin rights to Repository.` |
| Web comment form | `There was a problem saving your comment. Please try again.` |

The web form message also appears during GitHub outages, so it proves nothing
alone. Confirm the block with `gh issue comment` or the REST POST first. Once
one of them names the block, a retry or another token does not help while the
block is active. A personal account's block lasts until the owner lifts it; an
organization can also set a block that expires on its own. Stop, tell the user which account is blocked in which
repository, and hand over the comment text so they can choose another route.

## Closing your superseded work

Close with a reference to what supersedes it and what, if anything, of yours
remains useful (offer it as a follow-up, do not relitigate). The goodwill from
a clean retreat is worth more than the PR was.
