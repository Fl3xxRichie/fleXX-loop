#!/usr/bin/env bash
# fleXX-loop installer: put the three skills where THIS machine's Hermes reads them.
#
#   bash scripts/install.sh              # install / upgrade
#   bash scripts/install.sh --dry-run    # show the resolved paths and diffs only
#   bash scripts/install.sh --check      # exit 1 if the installed copy differs from the repo
#
# Every replaced skill directory is backed up to <name>.bak-<timestamp>, because the
# running copy is often newer than the repo: hand-edited lessons live there.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS=()
while IFS= read -r d; do SKILLS+=("$d"); done < <(find "$REPO/skills" -mindepth 1 -maxdepth 1 -type d | sort)

MODE="install"
case "${1:-}" in
  --dry-run) MODE="dry" ;;
  --check) MODE="check" ;;
  "") ;;
  *) echo "Usage: bash scripts/install.sh [--dry-run|--check]" >&2; exit 2 ;;
esac

resolve_root() {
  local candidate
  for candidate in \
    "${HERMES_HOME:-}/skills" \
    "${LOCALAPPDATA:-}/hermes/skills" \
    "$HOME/AppData/Local/hermes/skills" \
    "$HOME/.hermes/skills"; do
    [ -n "$candidate" ] || continue
    [ -d "$candidate" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

ROOT="$(resolve_root)" || {
  echo "Error: no Hermes skills directory found." >&2
  echo "Set HERMES_HOME, or copy the three directories from skills/ into your agent's skill root by hand." >&2
  exit 1
}

TARGET="$ROOT/software-development"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
VERSION="$(sed -n 's/^version:[[:space:]]*//p' "$REPO/skill-pack.yaml" | head -1)"

echo "fleXX-loop ${VERSION:-unknown}"
echo "  source: $REPO/skills"
echo "  target: $TARGET"
echo ""

DRIFT=0
for src in "${SKILLS[@]}"; do
  name="$(basename "$src")"
  dest="$TARGET/$name"
  if [ -d "$dest" ] && diff -rq "$src" "$dest" >/dev/null 2>&1; then
    echo "  = $name (up to date)"
    continue
  fi
  DRIFT=1
  if [ "$MODE" = "check" ]; then
    echo "  ! $name (differs from repo)"
    continue
  fi
  if [ "$MODE" = "dry" ]; then
    echo "  ~ $name would be replaced"
    diff -rq "$src" "$dest" 2>/dev/null | sed 's/^/      /' || true
    continue
  fi
  mkdir -p "$TARGET"
  if [ -d "$dest" ]; then
    cp -R "$dest" "$dest.bak-$STAMP"
    rm -rf "$dest"
    echo "  ~ $name replaced (backup: $name.bak-$STAMP)"
  else
    echo "  + $name installed"
  fi
  cp -R "$src" "$dest"
done

echo ""
if [ "$MODE" = "check" ]; then
  if [ "$DRIFT" -eq 1 ]; then
    echo "fleXX-loop: installed skills differ from this checkout."
    exit 1
  fi
  echo "fleXX-loop: installed skills match this checkout."
  exit 0
fi

if [ "$MODE" = "dry" ]; then
  echo "fleXX-loop: dry run, nothing written."
  exit 0
fi

# Verify the copies actually parse as skills.
fail=0
for src in "${SKILLS[@]}"; do
  name="$(basename "$src")"
  dest="$TARGET/$name/SKILL.md"
  if [ ! -f "$dest" ] || ! head -1 "$dest" | grep -q '^---'; then
    echo "  ! $name: missing SKILL.md frontmatter after install" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] && echo "fleXX-loop: $(( ${#SKILLS[@]} )) skill(s) installed and verified."
exit "$fail"
