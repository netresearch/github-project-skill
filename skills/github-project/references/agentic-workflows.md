# Agentic Workflows Reference

Authoring AI-agent workflows that run on GitHub Actions: `gh-aw` for compiling Markdown specs into hardened Actions YAML, and `gh-aw-firewall` (`awf`) for sandboxing the agent process inside the runner.

## When to use

- Building issue-triage bots, PR-review agents, doc-update agents, scheduled maintenance bots that run as GitHub Actions workflows.
- Hardening an existing agent workflow (permissions narrowing, SHA pinning, output filtering, tool allowlists) without hand-rolling the boilerplate.
- Adding egress control and credential isolation to an agent that calls external LLM/MCP endpoints.

## When NOT to use

- Non-agent CI workflows (lint, test, release). Use the standard patterns in `repo-setup-guide.md` and `reusable-workflow-security.md` instead.
- One-off `gh` scripts run by a maintainer locally — `gh-aw` targets workflows committed to a repo.

## `gh-aw` — GitHub Agentic Workflows

`gh` CLI extension that compiles a natural-language Markdown spec into a hardened GitHub Actions workflow YAML. Each spec is a single Markdown file with YAML front-matter (trigger, permissions, engine, tools) plus a body that describes what the agent should do in prose.

Source: https://github.com/github/gh-aw

### Install

```bash
gh extension install github/gh-aw
```

### What the compiler enforces

- **SHA-pinned `uses:`** for the agent-runtime actions it injects — no `@main`, no floating tags.
- **Narrowed `permissions:`** at the job level, derived from the front-matter declaration. Default is read-only; write scopes are opt-in per workflow.
- **Input sanitisation** for untrusted fields (issue body, PR title, comment body) that are interpolated into the agent prompt — these are passed via env vars, not `${{ }}` expansion in `run:` blocks. See `workflow-bash-patterns.md` for the underlying injection class.
- **Sanitised-output gating** for any step that uses agent output to perform a write (create comment, push branch, file issue). Agent output is filtered before it reaches the GitHub API call.
- **Tool allowlists** for the MCP servers and `gh`/`bash` surfaces the agent is permitted to call. Anything outside the allowlist is refused at runtime.
- **Engine pluggability** — Claude, GitHub Models, and others can be swapped via front-matter without rewriting the workflow.

### Minimal spec shape

```markdown
---
on:
  issues:
    types: [opened]
permissions:
  issues: write
  contents: read
engine: claude
tools:
  github:
    allowed: [add_issue_comment, get_issue]
---

# Triage Bot

Read the issue body and add one of the labels: bug, feature, question.
Post a one-sentence comment explaining the choice.
```

Saved as `.github/aw/triage-bot.md`, `gh aw compile` turns this into a fully-formed `.github/workflows/triage-bot.yml` with the hardening above baked in. Treat the compiled YAML as generated output — edit the Markdown, recompile, commit both.

### Relationship to the rest of the skill

- Compiled workflows still need org-level SHA pinning (`org-security-settings.md`) and supply-chain auditing of any non-default action they pull in (`reusable-workflow-security.md`).
- For reusable-workflow consumers, the gh-aw output is the "workflow" — apply `reusable-workflow-pitfalls.md` to the surrounding wiring.

## `gh-aw-firewall` — Agent egress firewall (`awf`)

Binary that wraps the compiled agent workflow in a Docker sandbox with a Squid proxy enforcing a domain allowlist, plus an optional API-proxy sidecar that holds the LLM credentials so the agent process itself never sees them.

Source: https://github.com/github/gh-aw-firewall

### Components

| Component | Role |
|-----------|------|
| Squid proxy | Enforces an outbound domain allowlist. All agent egress goes through it. |
| Agent container | The compiled `gh-aw` workflow runs here, network-restricted to the proxy. |
| API-proxy sidecar (optional) | Holds the Anthropic/OpenAI/GitHub Models API key; injects auth headers; agent only sees the proxy endpoint, never the secret. |

### When to layer `awf` on top of `gh-aw`

- Agent calls third-party LLM/MCP endpoints and you want the API key out of the agent process's environment (defence against prompt-injection-driven exfiltration).
- You want a hard, declarative allowlist of domains the agent may reach — not a `harden-runner` post-hoc audit.
- The workflow ingests untrusted content (issue bodies, PR diffs from forks, web fetches) and the agent has any write permission.

### When you DON'T need `awf`

- Agent only uses `GITHUB_TOKEN` via the `gh` CLI inside the same repo and makes no external calls. `gh-aw`'s permission narrowing is sufficient.
- Workflow is on a private repo with no fork PR triggers and you trust all input authors.

## `awf` vs `step-security/harden-runner`

They are **not mutually exclusive** and solve adjacent problems:

| | `harden-runner` | `awf` |
|---|---|---|
| Scope | The GitHub Actions runner VM | The agent process inside the workflow |
| Mechanism | eBPF egress monitoring + allowlist on the runner | Squid proxy + Docker network isolation around the agent container |
| Credential isolation | No — secrets in env are visible to all steps | Yes (with API-proxy sidecar) — LLM key never reaches agent |
| Detection vs prevention | Both, configurable | Prevention (proxy refuses non-allowlisted egress) |
| Applies to | Any workflow | Agent workflows specifically |

A defence-in-depth setup uses both: `harden-runner` at the runner level (covers all steps including `actions/checkout`, `setup-*`, etc.) and `awf` around the agent container (adds credential isolation and a narrower allowlist scoped to LLM/MCP endpoints).

## Audit checklist for an agentic workflow

Before merging a new agent workflow:

- [ ] Spec is committed alongside the generated YAML; CI regenerates and diffs to detect drift.
- [ ] Front-matter `permissions:` is the minimum needed — no `write-all`, no `secrets: inherit`.
- [ ] Tool allowlist is explicit — no wildcard MCP servers or `bash` with unrestricted command set.
- [ ] Untrusted input fields go through env-var passing, not direct prompt interpolation (gh-aw does this by default — verify in compiled YAML).
- [ ] If the agent has any write scope and ingests fork-PR content: `awf` is enabled or the trigger excludes untrusted authors.
- [ ] LLM credentials are stored as repository or environment secrets, never in workflow files; with `awf`, they live in the API-proxy sidecar and are not exposed to the agent step.
- [ ] Agent workflow has `concurrency:` scoped to the triggering issue/PR (not a static repo-wide group) so concurrent issues/PRs don't serialise unnecessarily — e.g. `group: ${{ github.workflow }}-${{ github.event.issue.number || github.event.pull_request.number || github.sha }}`.

## Related

- `reusable-workflow-security.md` — supply-chain trust + SHA pinning that applies to any action the compiled workflow references.
- `workflow-bash-patterns.md` — the injection class that gh-aw's input-sanitisation flow defends against.
- `security-config.md` — `harden-runner` setup at the runner level.
- `org-security-settings.md` — org-wide `sha_pinning_required` setting that `gh-aw` output already complies with.
