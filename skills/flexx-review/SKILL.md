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
git branch -r | grep -v "HEAD" | grep -v "main\|master" | sed 's|origin/||'
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

**Scope creep check:** Compare every changed file/hunk against the ACs and relevant files list. Flag any change that is not traceable to an AC as `[SCOPE-CREEP]`. This includes:
- Files changed that are not in the relevant files list and not newly created for an AC
- Refactors, renames, or cleanups not required by any AC
- Dependency changes not required by any AC

**Run tests:** Check out the branch and run the project's test suite, lint, and typecheck. Record pass/fail counts. If tests fail, that is a `[DEFECT]` finding in section 1. If the project has no test suite, note it but do not block merge unless the change is high-risk.

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
Yes — review evidence is complete. Flexx makes the final merge decision.
| No — issues in section 1 must be resolved first.
```

## 5. Checking scope

Non-goals are binding. If a finding requires behavior excluded by an NG-N, record it as `[SCOPE-CONFLICT]` and DO NOT prescribe a fix. Flexx must resolve the contradiction.

## Hard rules

- Never merge or push commits.
- Never approve through formal GitHub review buttons.
- Never change the AC-N or NG-N IDs in the original spec.
- Review against the contract, not your personal preference.
- If tests or CI are missing, note it but only block merge if the change is high-risk.