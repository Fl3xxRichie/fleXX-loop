# Changelog

## 1.1.0 — 2026-11-02

Makes the repo the source of truth and moves the loop's guarantees from prose into code.

### Added
- `scripts/loop-lint.py` — task contract validator (frontmatter, slug/filename match, status and
  priority enums, `claimed_at` rules, `depends_on` cycles, required sections, sequential AC/NG
  ids, AC-references-NG detection, state-marker consistency, blocked→ready without `## Resolution`).
  `--json` and `--strict` modes.
- `scripts/install.sh` — resolves the skill root this machine actually reads, backs up every
  replaced skill directory, verifies the copy parses, and offers `--dry-run` / `--check` (drift gate).
- `scripts/mark-merged.sh` — the only writer of `merged`. Proves ancestry of the branch tip (or
  the `[BUILT]` commit when the branch was deleted), appends `[MERGED <sha> <date>]`, syncs the
  out-of-repo queue copy, refuses squash merges.
- `git-hooks/{pre-commit,post-commit,_lib.sh}` — hooks as reviewable files instead of a heredoc.
- `tests/test_loop_lint.py` (24 tests) and `tests/hook-smoke.sh` (19 assertions, stub `hermes`).
- `.github/workflows/ci.yml`.

### Fixed
- Hook fired on `HEAD~1`, which breaks on root commits, amends and merges; it now uses `git diff-tree`.
- Hook re-dispatched a build after the builder's own task-file commits; `FLEXX_LOOP_ACTIVE=1` is
  exported to the child and checked at the top of the hook.
- Hook ran `hermes chat` synchronously, so `git commit` blocked for the whole build; dispatch is
  now detached and logged.
- No single-flight guard: two commits could start two builds. Atomic `mkdir` lock, child pid
  recorded, stale lock reaped only when the pid is dead.
- Priority ordering was ignored when several tasks went ready in one commit; every candidate is
  now ranked (priority, then `created`, then filename) before a pick is made.
- `python3` on Windows can resolve to a Store shim that cannot execute; the interpreter is now
  proven with `-c "import sys"` before use, and lint fails open rather than blocking commits.
- MSYS `/tmp` paths passed to native Windows python; converted with `cygpath -m` when available.
- A failed `git show` truncated a staged task file to empty and then failed lint; the blob is
  checked with `cat-file -e` first.
- README installed into `~/.hermes/skills`, which is not the active skill root on this machine,
  and used `cp -r` with no backup — it could silently downgrade the running skills.

### Changed
- `skills/` re-synced from the copies in daily use, plus the sections that had only ever existed
  in the live copies: the viability-memo path, the review-verdict fix loop, orchestration
  mechanics, `references/local-first-dev-infra.md`, `references/unattended-run-mechanics.md`,
  `scripts/watch-agent.sh`, `scripts/cdp-geometry-probe.mjs`.
- Spec: the human gate is restored as a `clarify` tap (mark agent-ready / keep draft / another
  round) — Flexx decides, the agent never self-promotes.
- Review: a merge handoff section replaces the old merge button. Review prints the merge command
  and stops; it never merges.
- `skill-pack.yaml` is a real manifest (version, skills, assets).

## 1.0.0 — 2026-07-27

First release: spec / build / review skills, AC-N and NG-N contract, task frontmatter, atomic
lock, stale-lock TTL, blocked reactivation, branch discovery, git-hook dispatch, clarify buttons.
