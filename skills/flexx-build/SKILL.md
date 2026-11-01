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
- Tree must be clean (`git status --porcelain` empty). If dirty, report paths and end. Never stash, reset, revert, or commit unrelated work, and never restore or overwrite a file you did not edit, even when it looks like a stray test edit or carries an annotation: foreign changes get reported, not cleaned.

## 1. Pick a task

Read all files in `.hermes/tasks/` or `~/.hermes/tasks/`. Tasks are `.md` files with YAML frontmatter and AC-N acceptance criteria.

Tasks are picked in this order:
1. Tasks with `status: agent-ready` in frontmatter (or the text "AGENT-READY" in content)
2. Tasks that Flexx explicitly said "do this" in the current conversation

Among agent-ready tasks, sort by:
1. `priority` field descending: `high` > `normal` > `low` (default `normal` if absent)
2. `created` date ascending (oldest first) within the same priority
3. Alphabetical slug order as final tiebreak (deterministic, no randomness)

**Skip tasks where:**
- `status: in-progress` - another build pass already claimed it (check for stale in-progress below)
- `status: built` or `status: merged` - already done
- `status: blocked` - waiting on Flexx answer
- `depends_on` lists a slug that is not yet `status: merged` - skip and report, but verify against git first: a dependency whose task file tail already carries a `[MERGED <sha>]` record and whose merge commit sits in the default-branch history counts as merged even when its frontmatter still lags at `built` - proceed, and note the stale field in the report. Only a dependency with no merge commit behind it is a real skip.

**Stale in-progress recovery:** If a task is `status: in-progress`, check `claimed_at` in frontmatter:
- If `claimed_at` is less than 30 minutes old, skip it. The agent is likely still working.
- If `claimed_at` is older than 30 minutes AND no matching `task/<slug>` branch exists on origin, the agent crashed. Mark it back to `status: agent-ready` and pick it up.
- If `claimed_at` is older than 30 minutes AND the branch DOES exist, the agent finished building but didn't mark `built`. Check if the branch is pushed and reviewable. If so, mark `status: built` and trigger review. If not, mark `status: agent-ready` and pick it up.

If no `agent-ready` tasks exist, check for `blocked` tasks. If any exist, report the count and list them with the actual blocked question so Flexx sees what needs answering:

```
No agent-ready tasks found. 2 task(s) waiting on you:
- <slug>: [BLOCKED <date>] <full question text from task file>
- <slug>: [BLOCKED <date>] <full question text from task file>
```

Then end the pass. Do not invent work.

## 2. Read the contract

Parse the task file. Extract:
- Every AC-N (must implement every single one)
- Every NG-N (must NOT cross any of these)
- Relevant files and verification steps

If an AC is genuinely ambiguous or conflicts with an NG, stop. Do not guess. Go to step 9 (Blocked).

A verify step whose end state depends on an artifact a LATER task owns (a table, a route, seeded data) is not a blocking ambiguity: that task's ACs and relevant-files list own the artifact. Implement the mechanism your task owns, make the verify step true as far as it can be today, and state the reading in the report; never invent the other task's artifact to satisfy wording (it trespasses on their contract and collides with their migrations).

**An explicit go on a task whose `depends_on` is still draft is a fork, and it is resolved in the lock commit.** Either build the dependency first, or amend BOTH specs: drop the dependency from the task you are claiming AND update the dependency spec's own column/check contract so the two never disagree about a shared migration. A `source` check listing two values in one spec and three in the other guarantees a migration conflict the moment both are built. Record the amendment in the report; silently building on a draft dependency leaves the queue lying to the next pass.

If an AC contradicts the conversation's settled decision (a price, quota, or tier the user explicitly chose in an interview), ask ONE focused question and correct the spec file in the same pass. A drafting mistake in the spec is still the binding contract until corrected — one question is cheaper than silently building the other number.

## 3. Claim the task (atomic lock)

Before touching any code, make the lock visible to other agents:

1. Edit the task file: set `status: in-progress` and add `claimed_at: <ISO timestamp>` to frontmatter.
2. Commit this change on the default branch with message `lock: <slug>`.
3. Push to origin immediately.

This is the lock. Any other agent that fetches after this point will see `status: in-progress` and skip the task. The window where two agents can both claim is now the gap between "read agent-ready" and "push lock commit" which is seconds, not hours.

If the queue lives outside the repo (the orchestrator hands over a tasks directory that is not in the git working tree), commit a copy of the task file into the repo at `.hermes/tasks/<slug>.md` as part of the lock commit. Review and the built/sync flow bind to the in-repo copy; pipeline readers pick from the out-of-repo copy. Keep both updated through built/sync.

**The in-repo commit does not update the out-of-repo copy.** Edit both files at lock time (`status: in-progress` plus `claimed_at`), and at step 8 diff the two before closing: a lock written only into the repo leaves the pipeline copy reading `status: draft`, so a resumed orchestrator picks the task again and builds it twice.

If the push fails because origin moved (another agent locked a different task), fetch and rebase on the default branch, then retry the push. Use `git pull --rebase` (not merge) so there's no conflict resolution needed - the lock commit only touches one task file, so the rebase is clean. If it fails because another agent already pushed `in-progress` for THIS task, they won the race. Stop and end the pass.

## 4. Build

- Create a branch named `task/<slug>` from the latest default branch.
- Implement every AC-N. Use the repository's existing patterns, style, and naming.
- Add tests when the change affects logic, data flow, permissions, integrations, or anything user-facing.
- Never touch behavior outside the contract. No opportunistic refactors. No unrelated cleanups. If you find something that needs fixing, note it in the report - do not fix it.
- When the task stands up local development infrastructure (Docker Postgres, migrations, storage drivers, health checks, or any tsx/drizzle script that talks to the database), start from the known-good shapes and traps in `references/local-first-dev-infra.md` - including the script-lifecycle trap: a Postgres client pool that is never ended keeps the process alive after it has finished its work.
- **Commit the branch in stages on a large pass.** A task with 15+ ACs can outrun a session or hit its tool-iteration cap before the final gate. Commit each slice as it goes green (schema + pure lib, then routes, then UI) with a message naming what was verified, so the branch never holds a session's worth of unverified work in the working tree. A cap or an app close can end the pass before `npm run ci`; a committed slice survives that, an uncommitted one is lost.

## 5. Verify

Run the project's lint, typecheck, build, and narrowest useful tests. All must pass before committing.

If a dev server or watcher is running and holds the build output directory (`.next`, `dist`, ...), prefer running the gate in a pristine copy of the tree over stopping the process: copy to scratch with robocopy (exclude `node_modules`, build dirs, `.git`, `.env.local`), run the repo's clean install (`npm ci`), then the full CI gate there. The same scratch copy then serves the gate's build output for a production `start` on a spare port, so Lighthouse / browser / screenshot QA runs against a prod build without touching the live dev server's `.next` - stop that server with `process_manage kill` when done (shell kill commands are approval-gated in unattended runs). Prod-build Lighthouse from that server: `CHROME_PATH="C:/Program Files/Google/Chrome/Application/chrome.exe" npx -y lighthouse <url> --only-categories=performance --output=json --output-path=<file> --chrome-flags="--headless=new" --quiet`. Non-destructive, needs no approvals (an unattended one-shot has no user to grant a process kill; a blocked attempt just burns the pass), and it doubles as clean-checkout proof of the exact tree. A still-running dev server usually hot-reloads new routes and env files: leave it alone and verify against it directly (route sweep, health endpoint). For the curl/grep assertion recipes that survive React SSR output (comment-split text nodes, duplicated RSC payload strings, rate-limiter bucket isolation for live auth checks), see `local-verify-and-env-debug`, section "Asserting on Server-Rendered HTML".

Long-running local steps (a full catalog sync, bulk image mirroring, a cold `npm ci`) start with `terminal(background=true, notify=true)`; a foreground call that outruns the tool timeout returns while its child tree may keep running detached. Treat every timed-out foreground job as possibly alive: before re-running it, enumerate live node processes and reap survivors (see `references/unattended-run-mechanics.md`). Stacked duplicate runs stay correct on idempotent pipelines but shift the created/updated counts the task is graded on and burn wall-clock.

Background and promoted processes start from a fresh environment: session `export`s are NOT inherited, so inline env values in the command itself (`DATABASE_URL=... npm run ci`). Values that live in the gitignored `.env.local` come via command substitution (`DATABASE_URL="$(grep '^DATABASE_URL=' ../store/.env.local | cut -d= -f2-)" npm run ci`) - `read_file` refuses `.env*` by design, and substitution keeps the value out of logs. See `references/unattended-run-mechanics.md`.

## 6. Commit

Write a commit message describing what changed and why. Use the existing repo's commit convention.

Push the branch.

## 7. Report

When Flexx asks whether anything is left before a merge, answer as three blocks in this order: what blocks the merge (each line with why it blocks and a size estimate), what is incomplete but not blocking, and the deploy preconditions (env vars to set first, prod migration, which alias to smoke). Then stop for his one-word go; a question about readiness is not merge authorization. He decides from that table, so keep it short and put a cost on every blocking line.

Report back to Flexx with:
- What was built (AC-N checklist with status)
- Branch name and commit hash
- Files changed and lines
- Test results
- Any edge cases not covered
- Any judgment calls where spec wording was loose (see step 2) - one line each, so review and Flexx can override cheaply
- If the pass produced or changed a runnable app: verify it running yourself before Flexx looks (route sweep, real-layout measurement, screenshots - see verified-fix-testing, "Handing A Verified Feature To The User To Click"). He expects checked-before-handover, not checked-after.

Then trigger review on the branch:

```bash
hermes chat -q "Review the branch 'task/<slug>'. Load the flexx-review skill, audit the branch against its spec, and post the verdict." --provider <provider> -m <model> -Q &
```

This fires review as a background one-shot. Do not wait for it to finish. The verdict will be delivered to chat when review completes. In a Hermes terminal session, fire it through the tool's own background support - `terminal(background=true, notify=true)`, plus `persist_on_release=true` so a long review survives session cleanup - with the output redirected to `review-<slug>.log` in the project root; a shell `&` appended inside the command is not the reliable path.

- **Pin provider/model explicitly** (a working one). The default provider can be out of credits or down: the one-shot then dies in seconds with `0 tool calls` and an "out of credits" banner — that is NOT a verdict. Poll once after ~30-60s to confirm it actually started; if it died, re-fire with explicit `--provider`/`-m`. Reviewing with a different model than the builder also reduces self-review bias.
- If one-shots keep dying on a dead default provider, check `config.yaml` `fallback_providers`: it must be a real YAML LIST, not a quoted string — a quoted string is silently ignored by every reader, so fallbacks never engage.

If `hermes` is not available (non-Hermes agent system), skip this step and tell Flexx to run review manually.

## 8. Done

Mark the task `status: built` in frontmatter. Append `[BUILT <commit-hash> <ISO date>]` to the end of the task file.

Append that marker idempotently: `grep -q '^\[BUILT' <file>` before writing, or delete the old marker line first. A retried step, or a search-and-replace that silently missed its pattern, leaves two `[BUILT]` lines, and the merge-time superset check (`grep -c '^-[^-]'`) then reports a phantom divergence. Push the task file change to the default branch. The builder's worktree normally still sits on `task/<slug>`, so make that default-branch commit from a temporary worktree (`git worktree add ../wt-build-sync <default>`, edit the file there, commit `docs: mark <slug> built`, push, `git worktree remove ../wt-build-sync`); the branch copy is then synced FROM the default, so the marker can never be erased by a wrong-direction checkout. Keep the task file byte-identical on the default branch and the `task/<slug>` branch — sync the other copy (`git checkout <default> -- .hermes/tasks/<slug>.md` + commit) so later cherry-picks and merges never conflict on it. Verify with `git diff <default> <branch> -- .hermes/tasks/<slug>.md`; empty output means identical blobs (line-ending differences in the worktree are invisible at the blob level and are fine). End the pass.

## 9. Blocked

Mark the task `status: blocked` in frontmatter. Append `[BLOCKED <ISO date>]` with one specific, answerable question to the task file. Do NOT guess. Do NOT implement half the ACs and skip the ambiguous one.

If running under cron, deliver the blocked question to Flexx via the cron delivery mechanism (the cron job's output is auto-delivered to chat). If not under cron, surface it in chat. Either way, end the pass.

## 10. Review verdict handling (fix loop)

When the review returns findings (or "No — not safe to merge"), do NOT redo the whole task:

1. **Verify every finding against the reviewed HEAD before patching.** Reviewers produce false positives ("this prop is not wired", "this flag was never applied") — check the actual file at the reviewed commit (`git show <head>:<path>` + grep for the symbol) before "fixing" anything. When a finding is stale, refute it with the file:line evidence and move on; "fixing" working code on a stale claim is worse than the claim.
2. Fix the real findings in place on the same `task/<slug>` branch. Keep each fix traceable to its finding label (`[AC-N]` / `[DEFECT]` / `[SECURITY]`).
3. Re-verify after fixing: typecheck, tests, and — for gates, permissions, money, or middleware-ordering fixes — a targeted ADVERSARIAL test for the exact defect (an already-exhausted quota, an expired plan, the first-request path), plus the repo's E2E battery where one exists.
4. Commit with a message that maps findings → fixes; append a `[REVIEW ROUND N <date>]` section to the task file listing findings, fixes, any verified false positives, and re-verification evidence.
5. Re-fire review on the updated HEAD, quoting the previous findings in the prompt so the reviewer verifies those specific fixes.
6. Sync the task file to the default branch so both copies stay identical (see step 8).
7. When the verdict flips to **safe to merge**, close in one bounded pass: fix only the section-2 items that prevent drift (hardcoded copy that can contradict a registry, etc.); for suggestions that conflict with a deliberate design decision, change nothing and record the disposition + reason in the task file. Re-run build/tests once, then sweep for dangles — `git status` clean, zero unpushed commits on BOTH branch and default with identical trees (`git diff --stat <default> <branch>` empty), spawned children exited, E2E rig containers/ports removed — and report the final SHAs. Stop there: the merge stays Flexx's call.

**If the branch was already merged when the verdict returns** (Flexx said deploy before review finished): do not reopen or rewrite merged history. Verify each finding against current main and the live deployment; fix production-blocking findings immediately as a fast-follow commit on main (and/or the deploy step they exposed), cherry-pick the fix to the branch so the trees stay identical, record `[REVIEW ROUND N]` with per-finding dispositions in the task file, and report the fast-follow SHAs. A fix cherry-picked into a branch whose scratch/dev worktree is still running lands there by hot reload - verify it live on that instance before re-firing review; no restart needed.

## 11. Orchestrating the loop from a parent session

When a parent session fires build one-shots (background `hermes chat -q ... -Q`),
these mechanics keep the loop observable and safe:

- **One-shots can run long past their own `status: built` marking** (extra polish
  and CI rounds after the marking commit). Do not kill one mid-write: check file
  mtimes first; minutes-old writes mean it is still working.
- **Watch, do not blind-poll.** A bounded wait loop tracking three cheap signals
  is enough: pid alive, HEAD hash, and a hash of `git status` output plus the
  newest src mtime. Wake on process exit, or on 15+ minutes of total quiet while
  still alive (it is composing its final report or stuck; both merit a look). Ready to run: `scripts/watch-agent.sh <pid> <git-dir> <task-file> [logs...]`; launch it as a foreground call whose timeout exceeds its cap (above 600s the runtime promotes it to a tracked background process that notifies on completion). Kill superseded watchers with `process_manage kill` (valid actions: list/poll/log/wait/kill; there is no 'stop'); keep one watcher per live pass.
- **Pid liveness on this box:** `powershell -NoProfile -Command 'if
  (Get-Process -Id <pid> -ErrorAction SilentlyContinue) { "1" } else { "0" }'`.
  `tasklist //FI` mangles its flags under git-bash and errors out. Kill with `powershell -NoProfile -Command "Stop-Process -Id <pid> -Force"`; `cmd //c "taskkill ..."` silently no-ops under git-bash and `kill -f` is invalid in MSYS.
- **The wake-up trick:** a foreground terminal call with a timeout above 600s
  auto-promotes to a tracked background process with notify on completion, so a
  wait loop returns control immediately and pings you at exit. Prefer that over
  busy-waiting in the foreground.
- **Never edit repo files while the one-shot runs.** Its tree operations revert
  uncommitted foreign edits; see `parallel-agent-collaboration` for the signature
  and the survival check. Land side fixes after it exits.
- **Run notes live in the project root, never in `.hermes/`.** That directory is
  a protected agent-instruction surface: writes there require live user consent
  and fail while the user is away.
- **A builder one-shot that dies mid-pass can leave the shared worktree checked out on its own branch.** Before any orchestrator git operation (`git add`/`commit`/`merge`), assert the current branch is the default (`git branch --show-current`); a "built:" marker committed while the worktree sat on `task/<slug>` landed on the branch while `git push origin <default>` reported "Everything up-to-date". To sync a task file to a branch while the main worktree stays on the default, add a temporary worktree (`git worktree add ../wt-sync task/<slug>`, commit there, `git worktree remove`) - never `git checkout <default> -- <file>` from the main worktree without checking which branch it sits on first: that exact sequence silently erased a built marker because the file was being synced branch<-default when the marker only existed on the branch.
- **After it exits:** read the flushed build log, resolve the dirty polish set
  (ci green means commit it on the branch; red means fix or restore those files),
  run ci, fire the review if the one-shot did not, then continue per section 10.
  When Flexx is away, keep the loop rolling autonomously and surface only
  blocking questions through his agreed channel.
- **Finding the review verdict.** A review one-shot the builder fired is a child
  of ITS session: it does not appear in your process registry ("No process with
  ID ..."). Detect completion from artifacts instead: the review log gains content and the task file gains a `[REVIEW ROUND N]` section. If it died without a verdict, fire one yourself (background, notify,
  log to review-<slug>.log) before merging. The flush can land BEFORE the process exits: when the log has content, judge completeness by STRUCTURE (it must run through its `## 3. Safe to merge` verdict and the evidence block, not stop mid-sentence), read it immediately, but still gate the merge on the pid having exited - the reviewer may be finishing cleanup writes. A NON-ZERO exit is not a failed review: a reviewer that writes its full verdict and then hits its tool-call ceiling on a final bookkeeping write exits 1 with a complete log, so read the structure before re-firing. Only an empty or mid-sentence log means the run died. While the one-shot is alive, a 0-byte log is NORMAL (output may buffer fully to the tee or stream progressively; both observed): never re-fire or re-arm watchers on log size alone, and never watch guessed child PIDs, since a venv python worker can exit while the hermes CLI wrapper keeps running. A structure-checked log, or process_manage poll for reviews you fired yourself, is the reliable signal - and a thorough review of a large pass can legitimately take 20-40 minutes. The reviewer may or may not leave a [REVIEW ROUND N] section in the task file; author it during close-out when absent.
- **One-shots die with the app, not with the session.** `persist_on_release` survives session end, `/new`, and compression, but NOT the host process: closing the Hermes desktop app kills every background one-shot mid-run. Death signature: a completion notification with exit code `1073807364` (`0x40010004`, STATUS_TERMINATE_PROCESS) and a tee log that stays 0 bytes forever. A 0-byte log alone still means nothing (see above) - liveness comes from the process registry for one-shots you fired yourself, or from a completion notification you never received; a dead process PLUS a 0-byte log means the run died. Recovery is idempotent: `rm -f` the stale log first so the next empty-or-flushed state is unambiguous, then re-fire the identical command (its full text sits verbatim in the process registry tail and in session history). On resume after a closed app, assume every in-flight one-shot died - triage before re-firing - and keep the app open for the duration of long passes.
- **Hand Flexx a clickable trial of unmerged work instead of making him wait.**
  When a review or build one-shot still runs, stand up a THIRD isolated instance
  (own worktree, port, and scratch DB) rather than pointing him at a scratch or
  the main server; hand him the URL + click path and watch its log/DB while he
  clicks. That env belongs to HIM: build and review one-shots must never use it
  as scratch. Run the full handover verification first (verified-fix-testing,
  "Handing A Verified Feature") - a trial whose images 404 reads as a broken
  feature even when the code is fine. Repo recipe: the flexxship-development
  skill (parallel-trial-env reference).
- **Merging the pass into the default branch** (only under the standing merge-on-safe policy, and only after asserting preconditions at the reviewed head: local tip == `origin/<branch>` (`git rev-parse`) and CI green for that head (`gh run list --branch <branch>`)): `git checkout <default>; git pull --ff-only; git merge
  --no-ff task/<slug>` and push. Expect a conflict on `.hermes/tasks/<slug>.md`:
  both sides append to the same tail ([BUILT], [REVIEW ROUND]). Resolve only
  after proving the branch copy is a superset: `git diff <default> task/<slug>
  -- .hermes/tasks/<slug>.md | grep -c '^-[^-]'` must print 0, then `git checkout
  --theirs -- <file>`, `git add`, `git commit --no-edit`. Any deletion lines mean
  the copies diverged for real: reconcile by hand. After merging, run the project's migrate command FROM the default branch (a migration added on the branch only becomes applicable once its file exists there), re-sweep the app routes, then copy the in-repo task file over the out-of-repo queue copy and diff them. Land those record commits (task-file sync + any orchestrator doc edits) and push BEFORE firing the next pass's one-shot: the next builder's preflight hard-fails on a dirty tree, so an uncommitted record commit races it. Reclaim the pass's scratch dirs in the same close-out - announce the list to Flexx first (his standing rule for deletes near the repo) and prefix-guard each path before any `rm -rf`.

## Hard rules

- Never merge. Never enable auto-merge. Only Flexx touches the merge button. (Exception: when Flexx has set an explicit standing merge-on-safe-verdict loop policy for a project, the parent session orchestrating passes may merge after a safe review; record the policy in the task file. Never infer this from a casual remark.)
- One task per pass always.
- If you need Flexx to make a decision, stop. Never guess.
- Reactivating a blocked task is manual. Flexx (or a spec-loop follow-up) must flip `status` back to `agent-ready` himself. Never auto-flip blocked tasks based on chat replies.