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

**Stale in-progress recovery:** If a task is `status: in-progress`, check `claimed_at` in frontmatter:
- If `claimed_at` is less than 30 minutes old, skip it. The agent is likely still working.
- If `claimed_at` is older than 30 minutes AND no matching `task/<slug>` branch exists on origin, the agent crashed. Mark it back to `status: agent-ready` and pick it up.
- If `claimed_at` is older than 30 minutes AND the branch DOES exist, the agent finished building but didn't mark `built`. Check if the branch is pushed and reviewable. If so, mark `status: built` and trigger review. If not, mark `status: agent-ready` and pick it up.

If no `agent-ready` tasks exist, check for `blocked` tasks. If any exist, report the count and list them so they don't silently rot:

```
No agent-ready tasks found. 2 task(s) waiting on you:
- <slug>: <blocked question summary>
- <slug>: <blocked question summary>
```

Then end the pass. Do not invent work.

## 2. Read the contract

Parse the task file. Extract:
- Every AC-N (must implement every single one)
- Every NG-N (must NOT cross any of these)
- Relevant files and verification steps

If an AC is ambiguous or conflicts with an NG, stop. Do not guess. Go to step 8.

## 3. Claim the task (atomic lock)

Before touching any code, make the lock visible to other agents:

1. Edit the task file: set `status: in-progress` and add `claimed_at: <ISO timestamp>` to frontmatter.
2. Commit this change on the default branch with message `lock: <slug>`.
3. Push to origin immediately.

This is the lock. Any other agent that fetches after this point will see `status: in-progress` and skip the task. The window where two agents can both claim is now the gap between "read agent-ready" and "push lock commit" which is seconds, not hours.

If the push fails because origin moved (another agent locked a different task), pull and retry. If it fails because another agent already pushed `in-progress` for THIS task, they won the race. Stop and end the pass.

## 4. Build

- Create a branch named `task/<slug>` from the latest default branch.
- Implement every AC-N. Use the repository's existing patterns, style, and naming.
- Add tests when the change affects logic, data flow, permissions, integrations, or anything user-facing.
- Never touch behavior outside the contract. No opportunistic refactors. No unrelated cleanups. If you find something that needs fixing, note it in the report - do not fix it.

## 5. Verify

Run the project's lint, typecheck, build, and narrowest useful tests. All must pass before committing.

## 6. Commit

Write a commit message describing what changed and why. Use the existing repo's commit convention.

Push the branch.

## 7. Report

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

## 8. Done

Mark the task `status: built` in frontmatter. Append `[BUILT <commit-hash> <ISO date>]` to the end of the task file. Push the task file change to the default branch. End the pass.

## 9. Blocked

Mark the task `status: blocked` in frontmatter. Append `[BLOCKED <ISO date>]` with one specific, answerable question to the task file. Do NOT guess. Do NOT implement half the ACs and skip the ambiguous one.

If running under cron, deliver the blocked question to Flexx via the cron delivery mechanism (the cron job's output is auto-delivered to chat). If not under cron, surface it in chat. Either way, end the pass.

## Hard rules

- Never merge. Never enable auto-merge. Only Flexx touches the merge button.
- One task per pass always.
- If you need Flexx to make a decision, stop. Never guess.