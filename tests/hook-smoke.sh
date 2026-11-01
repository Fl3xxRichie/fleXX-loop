#!/usr/bin/env bash
# fleXX-loop hook integration test.
#
#   bash tests/hook-smoke.sh
#
# Builds a throwaway repo in a temp dir, installs the hooks, and drives commits
# through them with a stub `hermes` on PATH. Asserts the properties that the v1
# hook broke: async dispatch, transition detection, single-flight locking, stale
# lock recovery, queue drain by priority, and the lint gate.
#
# Never touches the real hermes binary: the stub wins on PATH and the script
# fails loudly if `hermes` does not resolve inside the temp bin dir.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/flexx-hooks.XXXXXX")"
PASS=0
FAIL=0

cleanup() {
  if [ "${KEEP:-0}" = "1" ]; then
    printf '\nkept: %s\n' "$WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

mkdir -p "$WORK/bin" "$WORK/repo"
cat >"$WORK/bin/hermes" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
printf 'ACTIVE=%s\n' "${FLEXX_LOOP_ACTIVE:-unset}" >>"$STUB_LOG"
[ "${STUB_SLEEP:-0}" -gt 0 ] && sleep "$STUB_SLEEP"
exit 0
STUB
chmod +x "$WORK/bin/hermes"

export STUB_LOG="$WORK/stub.log"
export PATH="$WORK/bin:$PATH"
unset FLEXX_LOOP_ACTIVE

command -v hermes | grep -q "$WORK/bin/hermes" || { echo "refusing to run: hermes does not resolve to the stub"; exit 1; }

cd "$WORK/repo" || exit 1
git init -q -b main
git config user.email smoke@test.local
git config user.name smoke
mkdir -p .hermes/tasks

task() { # task <slug> [status] [priority]
  local slug="$1" state="${2:-draft}" prio="${3:-normal}"
  cat >".hermes/tasks/$slug.md" <<EOF
---
slug: $slug
status: $state
depends_on: []
created: 2026-11-02
priority: $prio
---

## Problem
Smoke.

## Acceptance Criteria
- [ ] AC-1 - It works.

## Non-goals
- NG-1: Nothing else.

## Relevant files
- src/x.ts - x

## How to verify
1. Look.
EOF
  [ -s ".hermes/tasks/$slug.md" ] || { echo "task(): failed to write $slug" >&2; exit 1; }
}

bash "$REPO_ROOT/scripts/setup-hooks.sh" "$WORK/repo" >"$WORK/setup.log" 2>&1
check "hooks installed" '[ -x .git/hooks/pre-commit ] && [ -x .git/hooks/post-commit ] && [ -f .git/flexx-loop-lint.py ]' "$(tail -3 "$WORK/setup.log")"

echo ""
echo "1. lint gate"
task broken-task agent-ready high
printf '\nthis line has no frontmatter fields but the file already has them\n' >>.hermes/tasks/broken-task.md
sed -i 's/^status: agent-ready/status: nonsense/' .hermes/tasks/broken-task.md
git add -A
if git commit -qm "bad task" 2>"$WORK/badcommit.err"; then
  bad "invalid task file is rejected" "commit succeeded"
else
  ok "invalid task file is rejected"
  grep -q 'contract violations' "$WORK/badcommit.err" && ok "rejection explains itself" || bad "rejection explains itself"
fi
check "stub never fired for a rejected commit" '[ ! -s "$STUB_LOG" ]'
git reset -q
rm -f .hermes/tasks/broken-task.md

echo ""
echo "2. draft commit does not dispatch"
task demo draft high
git add -A && git commit -qm "docs: draft task"
check "a valid task file commits" '[ "$(git log --oneline | wc -l)" -ge 1 ]'
sleep 1
check "no dispatch on draft" '[ ! -s "$STUB_LOG" ]'

echo ""
echo "3. draft -> agent-ready dispatches, asynchronously"
sed -i 's/^status: draft/status: agent-ready/' .hermes/tasks/demo.md
grep -q '^status: agent-ready' .hermes/tasks/demo.md || bad "sed did not flip the status" "$(grep '^status' .hermes/tasks/demo.md)"
START=$(date +%s)
git add -A && git commit -qm "ready: demo"
check "the ready commit landed" '[ "$(git log --oneline | wc -l)" -ge 2 ]' "$(git log --oneline | head -3)"
ELAPSED=$(( $(date +%s) - START ))
# The point is that the commit does not wait for a build (minutes), not that git is instant.
check "commit does not block on the build (<15s)" '[ "$ELAPSED" -lt 15 ]' "took ${ELAPSED}s"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$STUB_LOG" ] && break; sleep 0.5; done
check "build dispatched" 'grep -q "demo" "$STUB_LOG"'
check "child runs with the recursion guard set" 'grep -q "ACTIVE=1" "$STUB_LOG"'

echo ""
echo "4. single-flight lock blocks a second dispatch"
rm -f "$STUB_LOG"
sleep 30 &
LIVE=$!
mkdir -p .git/flexx-loop.lock
echo "$LIVE" >.git/flexx-loop.lock/pid
git commit -q --allow-empty -m "chore: while a build is live"
sleep 1
check "second dispatch suppressed while a build pid is alive" '[ ! -s "$STUB_LOG" ]' "$(cat .git/flexx-loop.log | tail -2)"
check "suppression is logged" 'grep -q "already running" .git/flexx-loop.log'
kill "$LIVE" 2>/dev/null

echo ""
echo "4b. a lock whose pid is dead is reaped"
echo 999999 >.git/flexx-loop.lock/pid
touch -d "30 seconds ago" .git/flexx-loop.lock 2>/dev/null || touch -t 197001010000 .git/flexx-loop.lock
git commit -q --allow-empty -m "chore: stale lock"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$STUB_LOG" ] && break; sleep 0.5; done
check "stale lock reaped and build dispatched" '[ -s "$STUB_LOG" ]'
check "reap is logged" 'grep -q "reaping stale lock" .git/flexx-loop.log'
rm -rf .git/flexx-loop.lock

echo ""
echo "5. queue drain picks the highest priority ready task"
rm -f "$STUB_LOG"
rm -rf .git/flexx-loop.lock
rm -f .hermes/tasks/demo.md
mkdir -p .hermes/tasks
task low-task agent-ready low
task urgent-task agent-ready high
mkdir -p src && echo "x" >src/x.ts
git add -A && git commit -qm "chore: unrelated change with two ready tasks"
check "the drain commit landed" '[ "$(git log --oneline | wc -l)" -ge 4 ]' "$(git log --oneline | head -2)"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$STUB_LOG" ] && break; sleep 0.5; done
check "drain dispatched something" '[ -s "$STUB_LOG" ]'
check "drain picked the high-priority task" 'grep -q "urgent-task" "$STUB_LOG"' "$(head -1 "$STUB_LOG" 2>/dev/null)"
grep -q "drain picked" .git/flexx-loop.log && ok "drain decision logged" || bad "drain decision logged"

echo ""
echo "6. no-op commits stay quiet"
rm -f "$STUB_LOG"
sed -i 's/^status: agent-ready/status: draft/' .hermes/tasks/urgent-task.md .hermes/tasks/low-task.md
git add -A && git commit -qm "docs: back to draft"
sleep 1
check "commit with no ready task dispatches nothing" '[ ! -s "$STUB_LOG" ]'

echo ""
printf 'hook smoke: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
