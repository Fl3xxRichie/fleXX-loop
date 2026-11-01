#!/usr/bin/env bash
# fleXX-loop hook helpers, sourced by pre-commit and post-commit.
# No `set -e` here: a hook must never abort a commit or a build.

fxl_git_dir() { git rev-parse --git-dir; }
fxl_root() { git rev-parse --show-toplevel; }

fxl_log() {
  local dir
  dir="$(fxl_git_dir)" || return 0
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$*" >>"$dir/flexx-loop.log" 2>/dev/null || true
}

# Tasks dir relative to the repo root.
fxl_tasks_rel() { printf '%s\n' "${FLEXX_LOOP_TASKS:-.hermes/tasks}"; }

# Repo-level config: .hermes/loop.conf (sourced, shell syntax).
fxl_load_conf() {
  local conf=".hermes/loop.conf"
  if [ -f "$conf" ]; then
    # shellcheck disable=SC1090
    . "./$conf" 2>/dev/null || true
  fi
  : "${FLEXX_LOOP_STALE:=5400}"     # seconds before a lock is considered dead
  : "${FLEXX_LOOP_DRAIN:=1}"        # pick any ready task, not only the one just committed
  : "${FLEXX_LOOP_PROVIDER:=}"
  : "${FLEXX_LOOP_MODEL:=}"
}

# status: value out of a task file on stdin.
fxl_status() { sed -n 's/^status:[[:space:]]*//p' | head -1 | tr -d '\r' | tr -d '"' | tr -d "'" | sed 's/[[:space:]]*$//'; }

# field <key> out of a task file on stdin.
fxl_field() { sed -n "s/^$1:[[:space:]]*//p" | head -1 | tr -d '\r' | tr -d '"' | tr -d "'" | sed 's/[[:space:]]*$//'; }

fxl_hermes() {
  if command -v hermes >/dev/null 2>&1; then
    command -v hermes
    return 0
  fi
  local candidate
  for candidate in \
    "${LOCALAPPDATA:-}/hermes/bin/hermes.exe" \
    "$HOME/AppData/Local/hermes/bin/hermes.exe" \
    "$HOME/.local/bin/hermes"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

fxl_python() {
  local candidate
  for candidate in python3 python; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    # A Windows Store shim resolves on PATH but cannot execute. Prove it runs.
    "$candidate" -c "import sys" >/dev/null 2>&1 || continue
    command -v "$candidate"
    return 0
  done
  return 1
}
