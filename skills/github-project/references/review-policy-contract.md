<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: Netresearch DTT GmbH -->

# Preserve the Review Policy Before Changing the Merge Process

Before a critical workflow, release, CODEOWNERS or merge-policy change, compare
the **documented policy** with the **effective enforcement on the PR's actual
base branch**. A green merge button, a team assignment and an approval record
prove different things.

## Record the contract and its enforcement

Record the source of each requirement: required number of distinct reviewers,
whether they must be humans, required qualification/team, covered paths,
current-revision approval, unresolved-thread policy, and any authorized bypass.
Do not infer this contract from a generic solo-maintainer template or copy a
weaker neighboring project's settings over an explicit project policy.

Read classic branch protection **and** effective rulesets for the actual base
([security-config.md](security-config.md#effective-branch-rules)). Resolve active
ruleset conditions, covered paths, required teams and bypass actors from their
full definitions. Record the endpoints and revision/time checked. A zero generic
approval count in one rule does not cancel a stricter team/path rule elsewhere.
A 403, ambiguous 404 or missing permission leaves enforcement unknown; it does
not prove the branch is unprotected.

For example, a policy requiring **two qualified human team members** is not met
by one generic approval, two bots, or a CODEOWNERS team with eight members and
zero actual approvals. Where the platform supports the exact team/path/count
constraint, prefer native enforcement. If it cannot enforce qualification, keep
an explicit operator gate and identify the gap; do not claim configuration alone
establishes reviewer expertise or lower the count to make a PR mergeable.

## Establish reviewer eligibility and actual approval

1. Inspect the CODEOWNERS file from the PR's **base branch**, including matching
   path precedence and syntax errors. Confirm the owner/team is valid and has
   the repository access required by GitHub. Team membership or write access is
   evidence of eligibility only; required domain qualification needs its own
   documented basis. Ask for the missing owner/qualified reviewer when needed.
2. Read submitted reviews, their author identity/type, state and commit ID. An
   author cannot approve their own PR. Count distinct eligible non-author humans
   when the project requires humans; bot reviews and automated approvals can
   supply feedback but cannot satisfy that human requirement.
3. Apply the current-revision rule from the contract. A review of an old head is
   not proof of approval of new code. Requalify after a substantive push; do not
   count dismissed reviews, comments, requested-but-unsubmitted reviews or team
   review requests as approval. Check blocking change requests and unresolved
   threads separately.
4. Before enqueue/merge, re-read the PR head and base, effective rules, approvals
   and checks. Bind the decision to those revisions. Independent agent review
   validates the patch; it does not impersonate or replace a required human.

## Guard stacked PRs on temporary branches

A child PR targeting its parent's feature branch may fall outside rulesets
limited to the default branch. It also reads CODEOWNERS from that temporary
base. Passing checks on the child do not establish default-branch protection.

Keep the child **draft** (and do not arm auto-merge or enqueue it) while its
temporary base lacks the intended policy. Record its intended final base and
the parent dependency in the body. Draft status is a concrete merge guard,
but not a substitute for native rules on the final target.

After the parent is actually merged:

1. Retarget the child to the intended protected branch; never merge it into the
   temporary parent branch just to satisfy the stack.
2. Re-read the new head/base and diff. Confirm the parent's changes are no
   longer duplicated and all intended child changes remain.
3. Recheck effective branch/path rules and CODEOWNERS, run the applicable checks
   for the retargeted diff, and obtain the contract's qualified approvals for
   the current revision. A retarget can change what reviewers must assess.
4. Mark ready only when the guarded transition is safe; enqueue/merge through
   the normal protected process once every requirement is met.

Do not repeatedly rebase or rerun every stacked PR while waiting: requalify the
actual transition and changed evidence, preserving current proofs where valid.

Sources: [CODEOWNERS and base-branch behavior](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners),
[protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches),
[available rules](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets).
