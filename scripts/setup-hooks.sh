#!/usr/bin/env bash
# fleXX-loop setup: install (or remove) the loop hooks in a repository.
#
#   bash scripts/setup-hooks.sh /path/to/repo
#   bash scripts/setup-hooks.sh /path/to/repo --uninstall
#
# Installs pre-commit (task contract lint) and post-commit (build dispatch) into
# .git/hooks. Backs up any hook it replaces. Writes .hermes/loop.conf defaults
# once and never overwrites an existing one.

set -euo pipefail

REPO_DIR="${1:-.}"
MODE="${2:-install}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SRC="$SCRIPT_DIR/../git-hooks"

if [ ! -d "$REPO_DIR/.git" ]; then
  echo "Error: $REPO_DIR is not a git repository" >&2
  exit 1
fi

cd "$REPO_DIR"
HOOKS_DIR="$(git rev-parse --git-dir)/hooks"
mkdir -p "$HOOKS_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

if [ "$MODE" = "--uninstall" ]; then
  for hook in pre-commit post-commit; do
    if [ -f "$HOOKS_DIR/$hook" ] && grep -q 'fleXX-loop' "$HOOKS_DIR/$hook"; then
      rm -f "$HOOKS_DIR/$hook"
      echo "[fleXX-loop] removed $hook"
    fi
  done
  rm -f "$HOOKS_DIR/_lib.sh"
  rm -f "$(dirname "$HOOKS_DIR")/flexx-loop-lint.py"
  exit 0
fi

[ -d "$HOOK_SRC" ] || { echo "Error: $HOOK_SRC missing (run from a full checkout)" >&2; exit 1; }

for hook in pre-commit post-commit; do
  if [ -f "$HOOKS_DIR/$hook" ] && ! grep -q 'fleXX-loop' "$HOOKS_DIR/$hook"; then
    mv "$HOOKS_DIR/$hook" "$HOOKS_DIR/$hook.pre-flexx-loop-$STAMP"
    echo "[fleXX-loop] backed up existing $hook -> $hook.pre-flexx-loop-$STAMP"
  fi
  cp "$HOOK_SRC/$hook" "$HOOKS_DIR/$hook"
  chmod +x "$HOOKS_DIR/$hook"
done
cp "$HOOK_SRC/_lib.sh" "$HOOKS_DIR/_lib.sh"
cp "$SCRIPT_DIR/loop-lint.py" "$(dirname "$HOOKS_DIR")/flexx-loop-lint.py"
chmod +x "$(dirname "$HOOKS_DIR")/flexx-loop-lint.py"

mkdir -p .hermes
if [ ! -f .hermes/loop.conf ]; then
  cat > .hermes/loop.conf <<'CONF'
# fleXX-loop configuration (sourced by the git hooks)
# Pin a provider/model that actually has credit. An unpinned one-shot can die in
# seconds with "out of credits" and no verdict.
# FLEXX_LOOP_PROVIDER=openrouter
# FLEXX_LOOP_MODEL=anthropic/claude-sonnet-4.5

# Seconds before a dispatch lock with a dead pid is considered abandoned.
FLEXX_LOOP_STALE=5400

# Wall-clock cap for the dispatched build one-shot, in seconds. 0 = unbounded.
# A hung child holds the single-flight lock and stalls the queue behind it.
FLEXX_LOOP_BUDGET=7200

# 1 = also build any other agent-ready task when a commit lands (queue drains itself).
# 0 = only build the task whose status just flipped to agent-ready.
FLEXX_LOOP_DRAIN=1

# Tasks directory, relative to the repo root.
FLEXX_LOOP_TASKS=.hermes/tasks
CONF
  echo "[fleXX-loop] wrote .hermes/loop.conf"
else
  echo "[fleXX-loop] kept existing .hermes/loop.conf"
fi

detect_python() {
  local candidate
  for candidate in python3 python; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    "$candidate" -c "import sys" >/dev/null 2>&1 || continue
    command -v "$candidate"
    return 0
  done
  return 1
}

if PY="$(detect_python)"; then
  if [ -d .hermes/tasks ]; then
    LINT_PATH="$SCRIPT_DIR/loop-lint.py"
    if command -v cygpath >/dev/null 2>&1; then
      LINT_PATH="$(cygpath -m "$LINT_PATH")"
    fi
    (cd .hermes/tasks && "$PY" "$LINT_PATH" .) || echo "[fleXX-loop] existing tasks have lint findings (see above)"
  fi
else
  echo "[fleXX-loop] no working python found; pre-commit lint will be skipped"
fi

cat <<'DONE'

[fleXX-loop] installed
  .git/hooks/pre-commit   -> task contract lint (blocks bad task files)
  .git/hooks/post-commit  -> build dispatch (detached, single-flight, logged)
  $GIT_DIR/flexx-loop.log -> every dispatch decision lands here

Next: commit a task file whose status flipped draft -> agent-ready.
DONE
