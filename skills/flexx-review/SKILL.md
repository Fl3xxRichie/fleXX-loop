---
name: flexx-review
description: Review loop. Audit a branch against its task spec.
---

# Flexx Review Loop

One pass = review one branch or recent commit against its spec. Under cron, each run reviews one piece of work then exits.

## When to use

Flexx says "review this," "check the build," "audit this PR," or wants automated review running on cron. Also use as a pre-commit gate before builds get merged.

## 1. Find work to review

Check git for branches that have been pushed but not yet merged:

```bash
git fetch origin
git branch -r | grep -v "HEAD" | grep -vE "^origin/(main|master)$" | sed 's|origin/||'
```

Or review the most recent commit Flexx asked about.

If nothing to review, say so and end the pass.

## 2. Find the contract

For each branch, find the associated task file in `.hermes/tasks/` (or `~/.hermes/tasks/`). Match in this order:
1. Exact slug match: `task/<slug>` -> `<slug>.md`
2. Fuzzy match: strip `task/` prefix, search all task files for one whose `slug` frontmatter or filename contains the branch slug as a substring (or vice versa)
3. If no match found, check git log for the branch - look for a task slug in commit messages

If no spec exists after all attempts, note it as a finding and review against general code quality only.

## 3. Read the contract and code

Parse every AC-N and NG-N from the spec.

Get the full diff against the default branch. Read every changed file in context.

**Pin the reviewed SHA.** Record `git rev-parse HEAD` when the pass starts and re-check it before posting. A running orchestrator can merge the branch and switch the worktree while you review, so the checkout is not a stable reference: read files with `git show <sha>:<path>` once it moves, and run probes, builds and browsers from a detached temp worktree at that SHA (`git worktree add --detach <tmp> <sha>`, remove it afterwards). Every runtime claim must come from a build of the reviewed SHA, not from whatever is checked out at verdict time.

**Scope creep check:** Compare every changed file/hunk against the ACs and relevant files list. Flag any change that is not traceable to an AC as `[SCOPE-CREEP]`. This includes:
- Files changed that are not in the relevant files list and not newly created for an AC
- Refactors, renames, or cleanups not required by any AC
- Dependency changes not required by any AC

**Discovery surface check:** If the task adds content that users should discover (tutorial, blog post, product page, etc.), verify it appears on the discovery surface (homepage, listing page, search index). If the discovery surface is hardcoded and was not updated, flag it as `[AC-N]` - the feature is not fully accessible to users even if the URL works.

**Run tests:** Check out the branch and run the project's test suite, lint, and typecheck. Record pass/fail counts. If tests fail, that is a `[DEFECT]` finding in section 1. If the project has no test suite, note it but do not block merge unless the change is high-risk.

**CI-parity check when the AC claims `npm run ci` is green:** a green run on the seeded dev database is not evidence for CI if the workflow provisions a different one. Read the CI workflow: if it only migrates, the db tests must create their own fixtures. Prove it by creating a scratch database, running the workflow's migrate step against it, and running the db-test script with `DATABASE_URL` pointed at that database. A test that asserts seed data exists (`assert.ok(product, ...)` on the catalog is the common shape) fails there while passing locally — that is an [AC-N] must-fix under the CI criterion, not a note. Drop the scratch DB and probe rows afterwards.

**Deploy-path check when the schema changes:** if the diff adds or alters columns/tables, trace how the schema reaches production: find the command that applies it (e.g. `prisma db push`) and confirm it is part of the documented deploy flow. In a migrations-free repo nothing applies schema implicitly, so a deploy doc or image that skips it is a must-fix, not a note: code referencing columns that were never pushed fails on first use in prod while every local test passes.

**Verify before you flag.** Every finding — must-fix AND should-fix — must be checked against the reviewed HEAD before it is written. For any "missing" / "not applied" / "not wired" / "does not cover" claim, run the grep or read that would find it and cite the file:line you inspected — a stale claim in either section costs the fixer a cycle on working code and discredits the whole round. Claims about a library's behavior (default options, canvas sizing, side effects) need the dependency's source read, not an assumption. If you could not verify a claim, put it in section 2 as a question, not section 1 as a defect. State whether you RAN something or merely READ it.

**UI claims: read the DOM, not the HTML source.** React splits adjacent text nodes with comment markers, so raw-HTML greps for visible copy ("4.0 (1)") report false misses; assert on `innerText` or the element's `aria-label`, and take geometry from `getBoundingClientRect`. Measure intrinsic heights (a card's content block or the specific row), not grid-row heights, because grid and flex stretch equalise every card in a row and hide a per-card 1px delta. Check `document.documentElement.scrollWidth === window.innerWidth` at each required width and report any control whose rect is under 44px. Run `scripts/cdp-geometry-probe.mjs` for this (Node 24 global WebSocket, no dependencies, Chrome via CHROME env).

## 4. Post the verdict

Post in this exact structure:

```
Review of <branch/commit>

## Summary
[One or two sentences on what this change does]

## 1. Must fix before merge
[Findings that block merge. Every finding starts with one of:]

- [AC-N] — The PR does not satisfy that acceptance criterion
- [DEFECT] — The implementation is broken while staying inside scope  
- [SECURITY] — A security issue blocks shipping
- [SCOPE-CONFLICT] — AC-N conflicts with NG-N

## 2. Should fix
- Suggestions that improve the code but do not block merge
- [SCOPE-CREEP] — Changes beyond the ACs that should be reverted or moved to a separate task

## 3. Safe to merge
Yes - review evidence is complete. Flexx makes the final merge decision.
No - issues in section 1 must be resolved first.
```

One-shot runs also write the verdict to `../review-<slug>.log` beside the project root, which is what the orchestrator reads back. Append when the file already has a round record; never clobber it.

## 5. Checking scope

Non-goals are binding. If a finding requires behavior excluded by an NG-N, record it as `[SCOPE-CONFLICT]` and DO NOT prescribe a fix. Flexx must resolve the contradiction.

## 5. Merge handoff (review never merges)

When section 3 says "Safe to merge: Yes", do not merge, do not open a PR merge, and do not flip
the task to `merged`. Hand the decision over with the exact command, and stop:

```
Review of task/<slug> complete: safe to merge.
Merge with: git checkout <default> && git pull --ff-only && git merge --no-ff task/<slug>
Then close the record: bash scripts/mark-merged.sh <slug>
```

`mark-merged.sh` is the only writer of the `merged` state: it proves the branch is an ancestor
of the default branch, flips `status`, appends `[MERGED <sha> <date>]`, and syncs the
out-of-repo queue copy. Flexx runs the merge, or a parent orchestrator does under the standing
merge-on-safe policy recorded in the task file. A review pass never does it, and a verdict is
not a merge authorization.

## Hard rules

- Never merge or push commits.
- Never approve through formal GitHub review buttons.
- Leave the worktree byte-identical to the reviewed HEAD when you finish: revert every probe edit (test files, HMR experiments, moved artifacts); if you restarted a running service, note it in the verdict. Never edit task files or specs: the verdict lives in your output (the review log for one-shot runs), and the fixer/orchestrator appends [REVIEW ROUND N] when it handles the findings.
- Never change the AC-N or NG-N IDs in the original spec.
- Review against the contract, not your personal preference.
- If tests or CI are missing, note it but only block merge if the change is high-risk.