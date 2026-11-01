# fleXX-loop

A three-skill dev loop for Hermes Agent: **spec → build → review**, with a contract a machine can enforce.

Each skill is a self-contained `SKILL.md`. Together they take a raw idea to a merged branch while you stay the only one who can merge.

```
idea ──spec──> task (draft) ──you──> agent-ready ──hook──> build ──> branch task/<slug>
                                                                        │
                                              review <─────────────────┘
                                                │
                                    "safe to merge" ──you merge──> mark-merged.sh
```

## Why v1.1 exists

v1.0 shipped three prose files and a hook that fired on `HEAD~1`. In real use that hook rebuilt
the same task after its own lock commit, blocked `git commit` for the length of a build, and
died silently when the provider had no credit. The skills also drifted away from the copies
actually running on the machine that uses them, so the repo advertised behavior the running
skills forbid (review merging, spec self-promoting to `agent-ready`).

v1.1 makes the repo the source of truth and moves the guarantees out of prose:

| Guarantee | How it is enforced now |
|---|---|
| A task file is well formed | `scripts/loop-lint.py`, wired into `pre-commit` |
| One build per pass | atomic `mkdir` lock in `$GIT_DIR/flexx-loop.lock`, child pid recorded |
| The build never recurses | `FLEXX_LOOP_ACTIVE=1` exported to the child, checked by the hook |
| Commits never wait on a build | dispatch is detached (`&` + `disown`), logged |
| A merge is real before it is recorded | `scripts/mark-merged.sh` proves ancestry first |
| Installed skills match the repo | `scripts/install.sh --check` diffs them |

## Install

```bash
# skills -> the skill root THIS machine actually reads
bash scripts/install.sh              # backs up each replaced skill dir as <name>.bak-<ts>
bash scripts/install.sh --dry-run    # show what would change
bash scripts/install.sh --check      # exit 1 when the installed copy differs from the repo
```

Resolution order: `$HERMES_HOME/skills`, `%LOCALAPPDATA%/hermes/skills`,
`~/AppData/Local/hermes/skills`, `~/.hermes/skills`. (`~/.hermes/skills` is not the active root
on every Hermes install — that is why the old README's `cp -r` silently installed nothing.)

Hooks, per repo that uses the loop:

```bash
bash scripts/setup-hooks.sh /path/to/repo
bash scripts/setup-hooks.sh /path/to/repo --uninstall
```

## The contract

```yaml
---
slug: <kebab-case>            # must equal the filename
status: draft                 # draft | agent-ready | in-progress | built | blocked | merged
depends_on: []                # slugs that must be MERGED before this builds
created: 2026-11-02
claimed_at: <set by build when locking>
priority: normal              # high | normal | low
---
```

Body sections, all required: `## Problem`, `## Acceptance Criteria`, `## Non-goals`,
`## Relevant files`, `## How to verify`.

- **AC-N** — observable outcome. Sequential from 1, never renumbered.
- **NG-N** — binding non-goal. An AC may not reference one; lint fails if it does.

## State machine

| State | Written by | Meaning |
|---|---|---|
| `draft` | spec agent | written, not approved |
| `agent-ready` | you (a tap, or editing frontmatter) | queued |
| `in-progress` | build, as the lock commit | claimed |
| `built` | build, with `[BUILT <sha> <date>]` | branch pushed |
| `blocked` | build, with `[BLOCKED <date>]` + one question | needs you |
| `merged` | `scripts/mark-merged.sh` only | on the default branch |

`mark-merged.sh` refuses to write `merged` unless the branch tip (or the `[BUILT]` commit, if
the branch was deleted) is an ancestor of the default branch. Squash merges break ancestry by
design and are reported, not recorded.

## Hooks

`pre-commit` lints staged task files and blocks on contract errors. It fails **open** on
infrastructure problems (no working python, unreadable temp dir) so a broken interpreter never
blocks your commits. Escapes: `git commit --no-verify`, `FLEXX_LOOP_SKIP=1`.

`post-commit` dispatches a build when a task **transitions** into `agent-ready` (root commits,
merge commits and amends included — it uses `git diff-tree`, not `HEAD~1`). With
`FLEXX_LOOP_DRAIN=1` it also picks any ready task left in the queue, highest priority first,
oldest second, filename last.

Every decision lands in `$GIT_DIR/flexx-loop.log`. If nothing fires, read that file first.

| Env | Effect |
|---|---|
| `FLEXX_LOOP_ACTIVE=1` | suppress dispatch (set automatically for the child) |
| `FLEXX_LOOP_SKIP=1` | disable hooks entirely |
| `FLEXX_LOOP_DRAIN` | `1` = build any ready task, `0` = only the one just committed |
| `FLEXX_LOOP_PROVIDER` / `FLEXX_LOOP_MODEL` | pin the one-shot; an unpinned provider that is out of credit dies in seconds with no verdict |
| `FLEXX_LOOP_TASKS` | tasks dir, default `.hermes/tasks` |
| `FLEXX_LOOP_STALE` | seconds before a lock with a dead pid is reaped |

Repo config lives in `.hermes/loop.conf` (written once by `setup-hooks.sh`, never overwritten).

## Lint

```bash
python3 scripts/loop-lint.py .hermes/tasks
python3 scripts/loop-lint.py .hermes/tasks --json --strict
```

| Code | Meaning |
|---|---|
| E001–E004 | frontmatter / slug shape (filename match, kebab-case) |
| E005–E007 | status enum, ISO `created`, priority enum |
| E008 / W001 | `claimed_at` required by `in-progress` / stale on other states |
| E009–E010, W002 | `depends_on` shape, self-dependency, cycles, unresolved dep |
| E020–E024 | missing section, no ACs, non-sequential ids, AC referencing an NG |
| E030–E032 | state markers missing; blocked task reactivated without `## Resolution` |
| W003–W007 | placeholders in ACs, checkbox-less criteria, duplicate `[BUILT]`, blocked without a question |

Exit 1 on errors, 2 on usage/infra, 0 clean. `--strict` also fails on warnings.

## Tests

```bash
python -m unittest discover -s tests -v   # 24 unit tests, stdlib only
bash tests/hook-smoke.sh                  # 19 assertions against a throwaway repo + stub hermes
```

`hook-smoke.sh` never calls the real `hermes`: it puts a stub on `PATH` and asserts dispatch,
recursion guarding, single-flight locking, stale-lock recovery, priority drain and the lint gate.

## Design rules

- **Only you merge.** Review prints the command; it never runs it. `mark-merged.sh` only records a merge that already happened.
- **One task per pass.** The lock is what makes that true across processes, not good intentions.
- **Contract first.** AC/NG ids are immutable once filed; lint is what keeps them honest.
- **Never guess.** Ambiguity blocks the task with one answerable question.
- **The repo is the source of truth.** `install.sh --check` is the drift alarm; the running skills are not a scratchpad.

## Requirements

- Hermes Agent (or any agent system that reads `SKILL.md`)
- Git, bash (git-bash on Windows is fine)
- Python 3.8+ for the linter (hooks fail open without it)
- `gh` optional

## License

MIT
