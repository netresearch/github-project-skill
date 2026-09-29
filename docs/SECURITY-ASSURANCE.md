<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Security assurance case — github-project-skill

This document states what a user can expect from this repository in terms of security, and argues why that expectation holds. Every claim names the file that implements it. Reporting a vulnerability: see the [security policy](https://github.com/netresearch/.github/blob/main/SECURITY.md). Components: [ARCHITECTURE.md](ARCHITECTURE.md).

## What the repository ships

| Part | Files | Runs where |
| --- | --- | --- |
| Skill instructions for an AI agent | `skills/github-project/SKILL.md`, `skills/github-project/references/*.md` | Read by the agent as instructions; not executed. The agent may run the `gh` and `git` commands they describe against the user's repositories. |
| Templates | `skills/github-project/assets/*.template` | Copied by the user or the agent into the user's repository; they run there as that repository's workflows and configuration. |
| Scripts | `skills/github-project/scripts/init-branch-protection.sh`, `skills/github-project/scripts/verify-github-project.sh` | On the user's machine, with the user's `gh` authentication. |
| Checkpoints | `skills/github-project/checkpoints.yaml` | Only when an assessment tool runs its `command` and `script` patterns in a user's project. |
| Repository checks | `Build/Scripts/check-plugin-version.sh`, `Build/hooks/pre-push`, `scripts/verify-harness.sh`, `tests/*.sh` | In this repository's CI and on contributors' machines. |

The repository ships no server component and no container image. It stores nothing and handles no user accounts or credentials of its own; the scripts use whatever token `gh` is authenticated with.

## Security requirements

1. `init-branch-protection.sh` changes branch protection only in the ways its header documents, and never overwrites protection it could not read.
2. `verify-github-project.sh` and the checkpoints only read: they change no file in the assessed project and send no write request to GitHub.
3. The skill content and templates recommend GitHub settings and workflows that do not hand pull request code a write token or secrets, and that require review before merge.
4. Nothing committed to this repository contains a secret.
5. A release carries the version that `.claude-plugin/plugin.json` states, and its archives can be verified against the build that produced them.

## Actors and trust boundaries

- **Skill user and agent.** The agent reads `SKILL.md` and the references and runs `gh`/`git` commands with the user's GitHub authentication. What it runs is decided by the agent and the user, not by this repository. `allowed-tools` in `SKILL.md` only pre-approves `gh`, `git`, `grep`, `Read` and `Write`; it does not take any tool away from the agent.
- **GitHub API.** Both scripts talk to GitHub only through `gh api`. Responses are treated as data: `init-branch-protection.sh` parses them with `jq` and builds request bodies with `jq --argjson` and `jq -R`, not by string concatenation.
- **Assessed repository.** `verify-github-project.sh` reads files in the directory it is given and, when the checkout's `origin` points at github.com, reads that repository's settings through the API. `checkpoints.yaml` patterns run in the assessed project's working directory with the privileges of whoever starts the assessment tool.
- **Contributors.** Changes reach `main` through pull requests, checked by the workflows in `.github/workflows/`. `.envrc` (used by direnv) sets `core.hooksPath` to `Build/hooks`, so a contributor who allows it runs the repository's `pre-push` hook.
- **CI.** Workflows run on GitHub-hosted runners with `permissions: {}` at the top level and grant each job only the scopes its called reusable workflow needs (`.github/workflows/*.yml`). The two `pull_request_target` workflows (`auto-merge-deps.yml`, `labeler.yml`) only call reusables that merge or label and do not check out pull request code; `auto-merge-deps.yml` passes two named secrets instead of `secrets: inherit`.

## Threats and countermeasures

| Threat | Countermeasure | Evidence |
| --- | --- | --- |
| A malformed or hostile `<owner>/<repo>` argument reaches the API path or the shell (CWE-20, CWE-78) | The slug must match `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`, the mode must be one of three fixed values; every variable is quoted | `init-branch-protection.sh` (argument parsing); `tests/init-branch-protection.sh` ("slug with shell metacharacters exits 2") |
| Existing branch protection is replaced by the template after a failed read, clearing required status checks | Only GitHub's explicit "Branch not protected" answer leads to a PUT; any other read error, or a successful answer without a `url` field, exits 3 without writing | `init-branch-protection.sh` (lines after "Check whether protection already exists"); `tests/init-branch-protection.sh` ("unreadable protection is not overwritten", "unexpected protection response is not overwritten") |
| An administrator's deliberate protection settings are silently reverted | On existing protection the script compares the fields the template sets, prints each difference and exits 1 without writing | `init-branch-protection.sh` (`check_field`); `tests/init-branch-protection.sh` ("drift is not corrected") |
| Adding required status checks drops other protection settings | `--from-current-checks` PATCHes only the `required_status_checks` subresource when it exists, and otherwise re-sends every field of the current protection | `init-branch-protection.sh` (`--from-current-checks` mode); `tests/init-branch-protection.sh` ("approval count is carried over", "enforce_admins is carried over") |
| A failed check is made a required status check, or checks are taken from an incomplete run | Only check-runs with conclusion `success` are used; a combined status other than `success` is reported as a warning | `init-branch-protection.sh`; `tests/init-branch-protection.sh` ("only successful check-runs, deduplicated, are required") |
| An audit reports a result that does not reflect the repository | `verify-github-project.sh` runs every section and fails when a required item is missing; the GitHub API part is skipped, and says so, when there is no github.com remote | `verify-github-project.sh`; `tests/verify-github-project.sh` |
| Pull request code runs with a write token or secrets in a user's repository (CWE-829) | The auto-merge and auto-approve templates use `pull_request_target` without checking out pull request code, gate on `github.event.pull_request.user.login`, and set explicit `permissions`; `pr-quality.yml.template` states that a checkout must not be added | `assets/auto-merge*.yml.template`, `assets/pr-quality.yml.template` |
| Merges bypass review or leave review threads unresolved | The branch protection template requires one approval and conversation resolution and forbids force pushes and deletions; checkpoints GH-30 and GH-31 read the protection back | `assets/branch-protection.json.template`, `checkpoints.yaml` |
| A reusable workflow or action is changed underneath its callers, or receives more secrets than it needs | The references explain SHA pinning of third-party actions and composite-action refs, transitive action risks, and passing named secrets instead of `secrets: inherit`; checkpoint GH-34 flags unpinned composite-action refs | `references/reusable-workflow-security.md`, `references/reusable-workflow-pitfalls.md`, `checkpoints.yaml` (GH-34) |
| A checkpoint modifies the assessed project | Every checkpoint is a file-existence, content or regex check, a `gh api` GET, or a shell/Python body that only reads files and exits with a status; none writes a file or sends a write request | `checkpoints.yaml` |
| A release is tagged with a version that disagrees with `plugin.json` | The pre-push hook runs `check-plugin-version.sh`, which fails when a semver tag at `HEAD` differs from `.claude-plugin/plugin.json` | `Build/hooks/pre-push`, `Build/Scripts/check-plugin-version.sh`; `tests/check-plugin-version.sh` |
| A released archive is tampered with | The release workflow publishes a Cosign-signed `SHA256SUMS.txt` and build-provenance attestations for the archives | `.github/workflows/release.yml` (calls the skill-repo-skill release reusable) |
| A secret is committed | Betterleaks scans every push to `main` and every pull request to `main` | `.github/workflows/security.yml` |
| A vulnerable or malicious dependency is added | Dependency review fails on vulnerabilities of severity high or above in a pull request; Composer Audit checks the Composer dependencies against known advisories; Renovate proposes updates, including pre-commit hook revisions | `.github/workflows/security.yml`, `renovate.json` |
| Insecure code or workflow patterns | Opengrep fails on findings of severity WARNING or above; zizmor analyses the workflows; ShellCheck runs on every `*.sh` file in Skill Validation | `.github/workflows/security.yml`, `.github/workflows/lint.yml` |
| A failing step continues with partial state | `init-branch-protection.sh`, `check-plugin-version.sh` and `verify-harness.sh` run with `set -euo pipefail`; `verify-github-project.sh` runs with `set -e` and counts results without commands that can fail | the scripts named |

Which of these checks must pass before a pull request can merge is set in the branch protection of `main`, not in this repository.

## Secure design principles applied

- **Least privilege:** the scripts send only the requests their mode needs; `verify-github-project.sh` sends none that write. Workflows here and in the templates start from explicit `permissions`.
- **Fail-safe defaults:** `init-branch-protection.sh` writes only when it has positively established the current state, and treats every other outcome as an error (exit codes 1 to 5 in its header).
- **Complete mediation of input:** arguments are validated before the first API call; API data enters request bodies through `jq`, never through the shell.
- **Economy of mechanism:** the scripts need bash, `gh`, `jq` and `git` and nothing else.

## What a user cannot expect

- The skill gives guidance; it does not enforce it. The agent runs `gh` with the user's token, and a token with admin rights can change any setting the references describe. Review what an agent proposes to run.
- `init-branch-protection.sh` writes branch protection with the user's token; it is not a dry run. Its baseline leaves `enforce_admins` off, so administrators can still bypass the protection until they enable it.
- The templates are examples to adapt. Some reference third-party actions by version tag (for example `step-security/harden-runner@v2`) rather than by commit SHA.
- `verify-github-project.sh` checks the presence of files and settings, not their content in depth, and reads the settings of whatever repository the checkout's `origin` points at.
- The checkpoints run shell commands in the assessed project when an assessment tool executes them; run them only in projects you trust. The LLM review checkpoints are judgements by a model and can miss issues.
- Security fixes follow the supported-versions rules of the organisation's security policy; older releases may not receive them.
