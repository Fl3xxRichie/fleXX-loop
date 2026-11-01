#!/usr/bin/env bash
# fleXX-loop close-out: record that a built task actually merged.
#
#   bash scripts/mark-merged.sh <slug> [--no-push]
#
# This is the ONLY writer of the `merged` state. It refuses to run unless the
# branch really is an ancestor of the default branch, so a queue can never claim
# a merge that did not happen.
#
# Handles the three shapes a merge leaves behind:
#   1. task/<slug> still exists        -> prove ancestry of the branch tip
#   2. branch deleted after merge      -> prove ancestry of the [BUILT <sha>] commit
#   3. squash merge (no ancestry)      -> refuse, print the manual override
#
# Keeps the in-repo task file and the out-of-repo queue copy identical.

set -euo pipefail

SLUG="${1:-}"
PUSH=1
[ "${2:-}" = "--no-push" ] && PUSH=0

if [ -z "$SLUG" ]; then
  echo "Usage: bash scripts/mark-merged.sh <slug> [--no-push]" >&2
  exit 2
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

TASKS_REL="${FLEXX_LOOP_TASKS:-.hermes/tasks}"
FILE="$TASKS_REL/$SLUG.md"
[ -f "$FILE" ] || { echo "Error: $FILE not found" >&2; exit 1; }

DEFAULT="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||')"
[ -n "${DEFAULT:-}" ] || DEFAULT="$(git rev-parse --abbrev-ref HEAD)"
git fetch origin "$DEFAULT" >/dev/null 2>&1 || true

# --- prove the merge -------------------------------------------------------
MERGE_SHA=""
if git rev-parse --verify --quiet "refs/remotes/origin/task/$SLUG" >/dev/null; then
  if git merge-base --is-ancestor "origin/task/$SLUG" "origin/$DEFAULT"; then
    MERGE_SHA="$(git rev-parse --short "origin/task/$SLUG")"
  fi
else
  BUILT_SHA="$(grep -o '\[BUILT [0-9a-f]\{7,40\}' "$FILE" | tail -1 | awk '{print $2}')"
  if [ -n "${BUILT_SHA:-}" ] && git merge-base --is-ancestor "$BUILT_SHA" "origin/$DEFAULT" 2>/dev/null; then
    MERGE_SHA="$BUILT_SHA"
  fi
fi

if [ -z "$MERGE_SHA" ]; then
  cat >&2 <<EOF
Error: task/$SLUG is not an ancestor of origin/$DEFAULT.

Nothing was changed. Either the merge has not happened, or it was squashed /
rebased (which rewrites the commit and destroys the ancestry proof).

If the work is genuinely on $DEFAULT, record it by hand:
  git log origin/$DEFAULT --oneline | head
  sed -i 's/^status:.*/status: merged/' $FILE
  echo '[MERGED $DEFAULT HEAD-COMMIT-SUBJECT]' >> $FILE
EOF
  exit 1
fi

# --- flip the state --------------------------------------------------------
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT_BRANCH" != "$DEFAULT" ]; then
  echo "Error: on '$CURRENT_BRANCH', not '$DEFAULT'. Check out the default branch first." >&2
  exit 1
fi

TMP="$(mktemp "${TMPDIR:-/tmp}/mark-merged.XXXXXX")"
awk 'BEGIN{done=0} /^status:/ && !done {print "status: merged"; done=1; next} {print}' "$FILE" >"$TMP"
mv "$TMP" "$FILE"

if ! grep -q '^\[MERGED' "$FILE"; then
  printf '\n[MERGED %s %s]\n' "$MERGE_SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$FILE"
fi

# --- sync the out-of-repo queue copy --------------------------------------
OUT_OF_REPO="$HOME/.hermes/tasks/$SLUG.md"
if [ -f "$OUT_OF_REPO" ] && [ "$(cd "$(dirname "$OUT_OF_REPO")" && pwd)" != "$(cd "$TASKS_REL" && pwd)" ]; then
  cp "$FILE" "$OUT_OF_REPO"
  echo "[fleXX-loop] synced $OUT_OF_REPO"
fi

git add "$FILE"
git commit -m "docs: mark $SLUG merged ($MERGE_SHA)" >/dev/null
echo "[fleXX-loop] $SLUG -> status: merged (ancestry $MERGE_SHA)"

if [ "$PUSH" -eq 1 ]; then
  git push origin "$DEFAULT"
fi

if command -v python >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
  PY="$(command -v python3 || command -v python)"
  [ -f scripts/loop-lint.py ] && "$PY" scripts/loop-lint.py "$TASKS_REL" --quiet || true

fi
