#!/usr/bin/env bash
# fleXX-loop setup script - installs git hooks into a repo
# Usage: bash setup-hooks.sh /path/to/your/repo

set -euo pipefail

REPO_DIR="${1:-.}"

if [ ! -d "$REPO_DIR/.git" ]; then
  echo "Error: $REPO_DIR is not a git repository"
  exit 1
fi

HOOKS_DIR="$REPO_DIR/.git/hooks"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Install post-commit hook
cat > "$HOOKS_DIR/post-commit" << 'HOOK'
#!/usr/bin/env bash
# fleXX-loop post-commit hook
# Triggers build agent when a task file changes to agent-ready

set -euo pipefail

# Get the list of changed files in this commit
CHANGED_FILES=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || git diff --name-only --cached)

# Check if any .hermes/tasks/*.md files changed
TASK_FILES=$(echo "$CHANGED_FILES" | grep -E '\.hermes/tasks/.*\.md$' || true)

if [ -z "$TASK_FILES" ]; then
  exit 0
fi

# Check if any changed file now has status: agent-ready
READY_TASKS=""
for file in $TASK_FILES; do
  if git show "HEAD:$file" 2>/dev/null | grep -q 'status: agent-ready'; then
    SLUG=$(git show "HEAD:$file" 2>/dev/null | grep '^slug:' | head -1 | sed 's/slug: *//' | tr -d '[:space:]')
    READY_TASKS="$READY_TASKS $SLUG"
  fi
done

if [ -z "$READY_TASKS" ]; then
  exit 0
fi

# Trigger Hermes build agent for the first ready task
SLUG=$(echo "$READY_TASKS" | tr -d ' ' | head -1)

echo "[fleXX-loop] Task '$SLUG' is agent-ready. Triggering build agent..."

# Run Hermes in one-shot mode
hermes chat -q "Work the queue. The task '$SLUG' just became agent-ready. Load the flexx-build skill, pick up this task, implement it, and push the branch. Then trigger review on the branch." 2>&1 || true

exit 0
HOOK

chmod +x "$HOOKS_DIR/post-commit"

echo "[fleXX-loop] Hooks installed in $REPO_DIR"
echo "[fleXX-loop] post-commit hook will trigger build when a task becomes agent-ready"
echo ""
echo "To test: commit a task file with 'status: agent-ready' in frontmatter"