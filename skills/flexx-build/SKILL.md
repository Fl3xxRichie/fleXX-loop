---
name: flexx-build
description: Build loop. Pick and implement a queued task.
---

# Flexx Build Loop

One pass = one task: implement one spec end to end. Under cron, each run processes one task then exits.

## 0. Preflight

Before changing any repo or file:

- Confirm the intended Git repository exists and `origin` is reachable.
- Detect the default branch with `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name` or `git symbolic-ref refs/remotes/origin/HEAD | sed 's|.*/||'`. Never assume `main`.
- Tree must be clean (`git status --porcelain` empty). If dirty, report paths and end. Never stash, reset, or commit unrelated work.

## 1. Pick a task

Read all files in `.hermes/tasks/` or `~/.hermes/tasks/`. Tasks are `.md` files with YAML frontmatter and AC-N acceptance criteria.

Tasks are picked in this order of priority:
1. Tasks with `status: agent-ready` in frontmatter (or the text "AGENT-READY" in content)
2. Tasks that Flexx explicitly said "do this" in the current conversation

**Skip tasks where:**
- `status: in-progress` - another build pass already claimed it (check for stale in-progress below)
- `status: built` or `status: merged` - already done
- `status: blocked` - waiting on Flexx answer
- `depends_on` lists a slug that is not yet `status: merged` - skip and report

**Stale in-progress recovery:** If a task is `status: in-progress` but has no matching `task/<slug>` branch on origin (branch was deleted, never pushed, or cron crashed), mark it back to `status: agent-ready` and pick it up. If the branch DOES exist, skip it - someone else is building it.

If no tasks exist, say so and end. Do not invent work.

## 2. Read the contract

Parse the task file. Extract:
- Every AC-N (must implement every single one)
- Every NG-N (must NOT cross any of these)
- Relevant files and verification steps

If an AC is ambiguous or conflicts with an NG, stop. Do not guess. Go to step 8.

## 3. Build

- Mark the task `status: in-progress` in frontmatter before starting. This is the lock.
- Create a branch named `task/<slug>` from the latest default branch.
- Implement every AC-N. Use the repository's existing patterns, style, and naming.
- Add tests when the change affects logic, data flow, permissions, integrations, or anything user-facing.
- Never touch behavior outside the contract. No opportunistic refactors. No unrelated cleanups. If you find something that needs fixing, note it in the report - do not fix it.

## 4. Verify

Run the project's lint, typecheck, build, and narrowest useful tests. All must pass before committing.

## 5. Commit

Write a commit message describing what changed and why. Use the existing repo's commit convention.

Push the branch.

## 6. Report

Report back to Flexx with:
- What was built (AC-N checklist with status)
- Branch name and commit hash
- Files changed and lines
- Test results
- Any edge cases not covered

Then trigger review on the branch:

```bash
hermes chat -q "Review the branch 'task/<slug>'. Load the flexx-review skill, audit the branch against its spec, and post the verdict." &
```

This fires review as a background one-shot. Do not wait for it to finish. The verdict will be delivered to chat when review completes.

If `hermes` is not available (non-Hermes agent system), skip this step and tell Flexx to run review manually.

## 7. Done

Mark the task `status: built` in frontmatter. Append `[BUILT <commit-hash> <ISO date>]` to the end of the task file. End the pass.

## 8. Blocked

Mark the task `status: blocked` in frontmatter. Append `[BLOCKED <ISO date>]` with one specific, answerable question to the task file. Do NOT guess. Do NOT implement half the ACs and skip the ambiguous one.

If running under cron, deliver the blocked question to Flexx via the cron delivery mechanism (the cron job's output is auto-delivered to chat). If not under cron, surface it in chat. Either way, end the pass.

## Hard rules

- Never merge. Never enable auto-merge. Only Flexx touches the merge button.
- One task per pass always.
- If you need Flexx to make a decision, stop. Never guess.