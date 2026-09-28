#!/usr/bin/env bash
# Adopt an existing worktree into the firstmate fleet.
#
# Usage: fm-adopt.sh <worktree-path> [--mode no-mistakes|direct-PR|local-only] [--yolo]
#
# Detects the project from git remote, registers it in data/projects.md,
# clones it into projects/<name>/, and prints a summary.
# The worktree itself is untouched; firstmate dispatches crewmates into
# treehouse worktrees and keeps projects/<name>/ in sync after merges.
#
# After the first PR merges, pull into your worktree with:
#   git -C <worktree-path> pull origin <default-branch>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
REG="$DATA/projects.md"

usage() {
  echo "usage: fm-adopt.sh <worktree-path> [--mode no-mistakes|direct-PR|local-only] [--yolo]" >&2
  echo >&2
  echo "  Adopt an existing git worktree so firstmate can dispatch crewmates" >&2
  echo "  for its project. The worktree itself is untouched; firstmate clones" >&2
  echo "  the project into projects/<name>/ and keeps it in sync after merges." >&2
  echo >&2
  echo "  --mode   Delivery mode (default: no-mistakes)" >&2
  echo "  --yolo   Let firstmate make routine merge decisions" >&2
}

WORKTREE=""
MODE="no-mistakes"
YOLO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)
      shift; MODE="$1"
      case "$MODE" in no-mistakes|direct-PR|local-only) ;; *)
        echo "error: unknown mode '$MODE' (use no-mistakes, direct-PR, or local-only)" >&2; exit 1 ;;
      esac ;;
    --yolo) YOLO="+yolo" ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown flag $1" >&2; usage; exit 1 ;;
    *) WORKTREE="$1" ;;
  esac
  shift
done

[ -n "$WORKTREE" ] || { usage; exit 1; }
[ -d "$WORKTREE" ] || { echo "error: $WORKTREE is not a directory" >&2; exit 1; }
[ -d "$WORKTREE/.git" ] || { echo "error: $WORKTREE is not a git repository" >&2; exit 1; }

# ── detect project ──────────────────────────────────────────────────

cd "$WORKTREE"
REMOTE=$(git remote get-url origin 2>/dev/null || true)
[ -n "$REMOTE" ] || { echo "error: no origin remote in $WORKTREE" >&2; exit 1; }

# Derive project name from the remote URL.
# github.com/owner/repo.git  →  repo
# github.com/owner/repo      →  repo
PROJECT=$(basename "$REMOTE" .git)
[ -n "$PROJECT" ] || { echo "error: could not derive project name from $REMOTE" >&2; exit 1; }

DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|.*/||' || true)
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH="main"

# ── register ────────────────────────────────────────────────────────

mkdir -p "$DATA" "$PROJECTS"

TODAY=$(date +%Y-%m-%d)

if [ -f "$REG" ] && grep -q "^\- $PROJECT " "$REG" 2>/dev/null; then
  echo "info: $PROJECT is already registered; updating delivery mode"
  # Replace existing line
  MODE_TAG="[$MODE"
  [ -n "$YOLO" ] && MODE_TAG="$MODE_TAG $YOLO"
  MODE_TAG="$MODE_TAG]"
  sed -i '' "s/^- $PROJECT .*/ - $PROJECT $MODE_TAG - (adopted $TODAY)/" "$REG"
else
  MODE_TAG="[$MODE"
  [ -n "$YOLO" ] && MODE_TAG="$MODE_TAG $YOLO"
  MODE_TAG="$MODE_TAG]"
  printf -- '- %s %s - (adopted %s)\n' "$PROJECT" "$MODE_TAG" "$TODAY" >> "$REG"
  echo "Registered $PROJECT [$MODE${YOLO:+ $YOLO}]"
fi

# ── clone ───────────────────────────────────────────────────────────

CLONE_DIR="$PROJECTS/$PROJECT"
if [ -d "$CLONE_DIR" ]; then
  echo "info: clone already exists at $CLONE_DIR"
else
  echo "Cloning $REMOTE into $CLONE_DIR ..."
  git clone --quiet "$REMOTE" "$CLONE_DIR"
fi

# ── summary ─────────────────────────────────────────────────────────

echo
echo "=== $PROJECT is ready ==="
echo "  Worktree:    $WORKTREE"
echo "  Clone:       $CLONE_DIR"
echo "  Mode:        $MODE ${YOLO:+(autonomous routine decisions)}"
echo "  Sync target: $CLONE_DIR (auto-updated after merges)"
echo
echo "  After a PR merges, pull into your worktree with:"
echo "    git -C $WORKTREE pull origin $DEFAULT_BRANCH"
echo
echo "  You can now say 'fix the login bug in $PROJECT' and firstmate"
echo "  will dispatch a crewmate."
