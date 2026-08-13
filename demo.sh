#!/usr/bin/env bash
#
# demo.sh - run two `claude` agents at the same time, in two separate git
# worktrees, on two genuinely independent tasks, then merge both back into
# main. Watch: neither agent's files, git index, or HEAD ever touch the
# other's, because each one only ever sees its own worktree directory.
#
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

MANAGER="./manager.sh"

SLUG_A="haiku"
TASK_A="Create a new file at sandbox/haiku.txt containing one original haiku (5-7-5 syllables, three lines) about git worktrees. Do not modify any other file."

SLUG_B="fact"
TASK_B="Create a new file at sandbox/fun-fact.txt containing exactly one interesting, true, single-sentence fact about octopuses. Do not modify any other file."

reset_slug() {
  # Makes the demo safely re-runnable: if a previous demo run left this
  # slug's branch/worktree behind (e.g. it crashed before merging), clear
  # it out so we start from a clean state.
  local slug="$1" branch="agent/$1" path="$REPO_ROOT/.worktrees/$1"
  if git show-ref --verify --quiet "refs/heads/$branch" || [[ -e "$path" ]]; then
    echo "==> clearing leftover '$slug' from a previous demo run"
    [[ -e "$path" ]] && git worktree remove --force "$path" 2>/dev/null || true
    git branch -D "$branch" 2>/dev/null || true
  fi
}

echo "########################################################################"
echo "# agent-worktrees demo"
echo "#"
echo "# Spawning two claude agents at once, each in its own git worktree:"
echo "#   $SLUG_A -> .worktrees/$SLUG_A on branch agent/$SLUG_A"
echo "#   $SLUG_B -> .worktrees/$SLUG_B on branch agent/$SLUG_B"
echo "########################################################################"
echo

reset_slug "$SLUG_A"
reset_slug "$SLUG_B"

echo
echo "==> dispatching both agents concurrently (this takes a minute or two)"
echo

"$MANAGER" spawn "$SLUG_A" "$TASK_A" &
PID_A=$!

"$MANAGER" spawn "$SLUG_B" "$TASK_B" &
PID_B=$!

STATUS=0
wait "$PID_A" || STATUS=1
wait "$PID_B" || STATUS=1

if [[ "$STATUS" -ne 0 ]]; then
  echo
  echo "==> one or more agents failed; see .worktrees/*.log for details" >&2
  exit 1
fi

echo
echo "########################################################################"
echo "# Both agents finished. Two independent branches, no collisions:"
echo "########################################################################"
"$MANAGER" list
echo
echo "sandbox/ now has, on each agent's own branch (not yet on main):"
git -C "$REPO_ROOT/.worktrees/$SLUG_A" show --stat --format="commit %h: %s" HEAD
echo "---"
git -C "$REPO_ROOT/.worktrees/$SLUG_B" show --stat --format="commit %h: %s" HEAD

echo
echo "########################################################################"
echo "# Merging both worker branches back into main"
echo "########################################################################"
"$MANAGER" merge "$SLUG_A"
"$MANAGER" merge "$SLUG_B"

echo
echo "########################################################################"
echo "# Done. Repo is clean, both agents' work is on main:"
echo "########################################################################"
"$MANAGER" list
echo
git log --oneline --graph -6
echo
ls sandbox/
