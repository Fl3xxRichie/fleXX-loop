---
name: flexx-spec
description: Spec interview loop. Use when asked to spec or plan a task.
---

# Flexx Spec Interview

Turns a raw idea into a task so complete that a build agent needs nothing beyond it. Works like plan mode: research the codebase, interview Flexx in rounds until confident, draft, confirm, file. Flexx is the product brain; you are the codebase brain. Never guess product decisions.

## When to use

Flexx says "spec this," "plan this feature," "write the issue for," "draft the task," or describes an idea he wants built. Also use when he asks "how would this work" about something that needs implementation.

## 1. Research before asking

Read the relevant code first. Find which files are involved, what patterns already exist, and what constraints apply. Never ask Flexx something the codebase can answer:

- Existing patterns (how are routes structured? how is auth handled?)
- Technical constraints (framework version, language, dependencies)
- What already exists that overlaps with this idea

If the idea touches a project like BotWall, pithos, or prxyauth, cd into that repo and read the relevant files silently. Only surface findings if they constrain a product decision.

**Trace the full surface.** Before finalizing the relevant files list, trace every path the user takes to see this feature:

1. Where does the data live? (dict, db, config file)
2. What renders it? (route, template, component)
3. Where does the user discover it? (homepage card, nav link, search index, sitemap)
4. Is discovery dynamic (loops over a dict/query) or hardcoded (manual HTML entries)?

If any discovery surface is hardcoded, add it to the relevant files list. A feature that works at its URL but does not appear on the homepage is incomplete.

## 2. Interview in rounds

Ask 1-4 questions per round, each with concrete options. Every question gets your recommended answer listed first. Examples:

- "For the payment page, where should it live? I think /dashboard/billing makes sense since it maps to the existing route structure."
- "Should failed payments redirect to a retry page or show a modal? Modal is cleaner but retry page lets them review their payment info."

Ask only genuine product decisions:

- Behavior forks: who sees it, what exactly happens, where does it live
- Scope boundaries: what is explicitly OUT of this issue
- Edge cases that change acceptance criteria: empty states, what happens on error, permission boundaries
- Data implications: existing records, migrations, API fields

After each round, fold the answers in and test:

> Could two different engineers read this spec and ship the same observable behavior?

If any ambiguity remains, ask another round. There is NO cap on rounds. A small fix might need two questions; a complex feature legitimately needs 10+. Never stop early because it feels like a lot of questions.

Once the test passes, stop. No filler questions.

## 3. Draft the spec

Use exactly this shape in the output:

```yaml
---
slug: <kebab-case-slug>
status: draft
depends_on: []
created: <ISO date>
claimed_at: <set by build agent when locking>
priority: normal
---
```
## Problem
[One or two sentences on what user/business problem this solves]

## Acceptance Criteria
- [ ] AC-1 - Observable, testable outcome one. Use Flexx's language.
- [ ] AC-2 - Observable, testable outcome two.
- [ ] AC-3 - ...

## Non-goals
- NG-1: What must NOT change in this task
- NG-2: What is explicitly excluded or saved for later

## Relevant files
- path/to/file.ts - why it matters

## How to verify
1. Numbered manual steps anyone can follow. Cover every AC.
```

Rules for the draft:

- Every acceptance criterion is an observable outcome. Every non-goal has a stable id.
- AC-N and NG-N IDs are the contract that build/review skills enforce. Do not change them after filing.
- No AC may require a non-goal. If one does, ask another round to resolve it.
- Each issue is one day of agent work or less. Bigger ideas become a chain of small issues. Order them so each is buildable from merged code of the prior ones.
- The frontmatter is the task schema. `slug` must match the filename. `status` starts as `draft`. `depends_on` lists slugs of tasks that must be merged before this one can be built. Leave empty if no dependencies.

## 4. Confirm

Show the draft in chat. Then use the `clarify` tool to get Flexx's decision:

- question: "Spec draft ready. Mark as agent-ready for the build loop?"
- choices: ["Mark Agent Ready", "Needs changes"]

If "Needs changes": ask what to fix, revise, and re-present the clarify button. Loop until "Mark Agent Ready" or Flexx abandons.

If "Mark Agent Ready": proceed to step 5.

## 5. Write to disk

Write the final spec to `.hermes/tasks/<slug>.md` in the project directory (if it's a specific project). Use the task title as the slug.

For generic/non-project tasks, write to `~/.hermes/tasks/<slug>.md`.

Also save as a TODO for the current session.

## 6. Queue for build

After writing the file, flip `status` from `draft` to `agent-ready` in the frontmatter (Flexx already confirmed via the button). Commit with message `ready: <slug>` and push.

If the git post-commit hook is installed (see README), build fires automatically. If not, use the `clarify` tool:

- question: "Task queued. Trigger build now?"
- choices: ["Work Queue", "Done for now"]

If "Work Queue": run the build agent via `hermes chat -q` with the build prompt (see flexx-build skill step 7).

If "Done for now": end. Flexx can say "work the queue" later.

## Hard rules

- Only flip to `agent-ready` after Flexx explicitly clicks the "Mark Agent Ready" button in the clarify call. Never auto-flip.
- Never start building during the spec interview.
- Never guess product decisions - ask.
- Output the final spec in a copyable code block so Flexx can paste it into Linear/GitHub issues.

## 6. Answering a blocked question

When a task is `status: blocked` and Flexx answers the question in chat:

1. Append a `## Resolution` section to the task file with Flexx's answer.
2. Flip `status` back to `agent-ready`.
3. Tell Flexx the task is back in the queue.

This is manual and explicit. The agent does not infer intent from casual chat replies. Flexx must clearly answer the blocked question before the agent reactivates the task.