#!/usr/bin/env bash
#
# manager.sh - dispatch, merge, and inspect per-agent git worktrees.
#
# Each "agent" gets its own git worktree (a separate working directory and
# index checked out on its own branch, sharing the same underlying repo
# object store). That means multiple `claude` processes can edit files and
# run `git commit` at the same time, in the same repo, without ever
# colliding on a shared working directory or HEAD.
#
# Subcommands:
#   manager.sh spawn <slug> "<task description>"
#       Create .worktrees/<slug> on branch agent/<slug> off main, then run
#       a `claude` agent inside it to perform <task description>. The agent
#       commits its own work; the worktree/branch are left in place for
#       review (nothing is auto-merged).
#
#   manager.sh merge <slug>
#       Merge agent/<slug> into main, then remove the worktree and branch.
#       Must be run with the repo root checked out on main.
#
#   manager.sh list
#       Show every agent/* worktree and branch, and whether each has
#       uncommitted work or has already been merged into main.
#
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKTREES_DIR="$REPO_ROOT/.worktrees"
BRANCH_PREFIX="agent/"
MAIN_BRANCH="main"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") spawn <slug> "<task description>"
  $(basename "$0") merge <slug>
  $(basename "$0") list
EOF
  exit 1
}

require_slug() {
  local slug="$1"
  if [[ ! "$slug" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "error: slug must contain only letters, numbers, '-' or '_' (got: '$slug')" >&2
    exit 1
  fi
}

# --- spawn ---------------------------------------------------------------

cmd_spawn() {
  local slug="${1:-}"
  local task="${2:-}"
  [[ -z "$slug" || -z "$task" ]] && usage
  require_slug "$slug"

  local branch="${BRANCH_PREFIX}${slug}"
  local worktree_path="$WORKTREES_DIR/$slug"

  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    echo "error: branch '$branch' already exists (slug '$slug' is in use)" >&2
    exit 1
  fi
  if [[ -e "$worktree_path" ]]; then
    echo "error: worktree path already exists: $worktree_path" >&2
    exit 1
  fi

  mkdir -p "$WORKTREES_DIR"

  echo "==> [$slug] creating worktree at .worktrees/$slug on branch $branch (off $MAIN_BRANCH)"
  git -C "$REPO_ROOT" worktree add "$worktree_path" -b "$branch" "$MAIN_BRANCH" >/dev/null

  local prompt
  prompt="$(cat <<EOF
You are an autonomous coding agent working alone in a dedicated git worktree,
checked out on branch '$branch' of this repository. No one else will touch
this worktree or this branch; you have exclusive control of it.

Your task:
$task

When you are done:
- Stage and commit your changes on this branch with a clear, descriptive
  commit message. Only commit files relevant to this task.
- Do not switch branches, run 'git worktree' commands, merge, or push.
- Stay inside this worktree directory; do not touch files elsewhere in the
  repository.
EOF
)"

  local log_file="$WORKTREES_DIR/$slug.log"
  echo "==> [$slug] dispatching claude agent (log: .worktrees/$slug.log)"

  # Run claude non-interactively, cwd'd into the agent's own worktree, so
  # its file edits and git commands are scoped to that worktree/branch only.
  (
    cd "$worktree_path"
    claude -p "$prompt" --permission-mode bypassPermissions
  ) 2>&1 | tee "$log_file"

  echo "==> [$slug] agent finished. Review with:"
  echo "      git -C $worktree_path log --oneline -5"
  echo "      git -C $worktree_path diff $MAIN_BRANCH..$branch"
  echo "    Merge with:"
  echo "      $(basename "$0") merge $slug"
}

# --- merge -----------------------------------------------------------------

cmd_merge() {
  local slug="${1:-}"
  [[ -z "$slug" ]] && usage
  require_slug "$slug"

  local branch="${BRANCH_PREFIX}${slug}"
  local worktree_path="$WORKTREES_DIR/$slug"

  if ! git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    echo "error: no branch '$branch' found (unknown slug '$slug')" >&2
    exit 1
  fi

  local current_branch
  current_branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
  if [[ "$current_branch" != "$MAIN_BRANCH" ]]; then
    echo "error: repo root is on '$current_branch'; run merge from '$MAIN_BRANCH'" >&2
    exit 1
  fi

  if [[ -d "$worktree_path" ]]; then
    if [[ -n "$(git -C "$worktree_path" status --porcelain)" ]]; then
      echo "error: .worktrees/$slug has uncommitted changes; commit or discard them first" >&2
      exit 1
    fi
  fi

  echo "==> [$slug] merging $branch into $MAIN_BRANCH"
  git -C "$REPO_ROOT" merge --no-ff "$branch" -m "Merge worker branch '$branch' (slug: $slug)"

  if [[ -d "$worktree_path" ]]; then
    echo "==> [$slug] removing worktree .worktrees/$slug"
    git -C "$REPO_ROOT" worktree remove "$worktree_path"
  fi

  echo "==> [$slug] deleting branch $branch"
  git -C "$REPO_ROOT" branch -d "$branch"

  rm -f "$WORKTREES_DIR/$slug.log"

  echo "==> [$slug] merged and cleaned up"
}

# --- list --------------------------------------------------------------

print_worktree_row() {
  local path="$1" branch="$2"
  local slug status merged

  slug="$(basename "$path")"

  if [[ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]]; then
    status="uncommitted changes"
  else
    status="clean"
  fi

  if git -C "$REPO_ROOT" merge-base --is-ancestor "$branch" "$MAIN_BRANCH" 2>/dev/null; then
    merged="merged"
  else
    merged="outstanding"
  fi

  printf "  %-16s %-24s %-20s %s\n" "$slug" "$branch" "$status" "$merged"
}

print_orphan_row() {
  local branch="$1"
  local slug merged

  slug="${branch#"$BRANCH_PREFIX"}"

  if git -C "$REPO_ROOT" merge-base --is-ancestor "$branch" "$MAIN_BRANCH" 2>/dev/null; then
    merged="merged"
  else
    merged="outstanding"
  fi

  printf "  %-16s %-24s %-20s %s\n" "$slug" "$branch" "no worktree" "$merged"
}

cmd_list() {
  printf "  %-16s %-24s %-20s %s\n" "SLUG" "BRANCH" "STATUS" "MERGED?"

  local seen_slugs="" any=0
  local path="" branch=""

  # git worktree list --porcelain emits stanzas separated by blank lines;
  # add a trailing blank line so the last stanza is flushed by the loop too.
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path="${line#worktree }" ;;
      "branch "*) branch="${line#branch refs/heads/}" ;;
      "")
        if [[ -n "$path" && "$path" == "$WORKTREES_DIR"/* ]]; then
          any=1
          print_worktree_row "$path" "$branch"
          seen_slugs="$seen_slugs $(basename "$path")"
        fi
        path=""
        branch=""
        ;;
    esac
  done < <(git -C "$REPO_ROOT" worktree list --porcelain; echo)

  # Branches under agent/ with no worktree (e.g. worktree dir was removed
  # manually outside of `manager.sh merge`) still count as outstanding work.
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    local slug="${branch#"$BRANCH_PREFIX"}"
    case " $seen_slugs " in
      *" $slug "*) continue ;;
    esac
    any=1
    print_orphan_row "$branch"
  done < <(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' "refs/heads/${BRANCH_PREFIX}*")

  if [[ "$any" -eq 0 ]]; then
    echo "  (no agent worktrees or branches)"
  fi
}

# --- dispatch ------------------------------------------------------------

case "${1:-}" in
  spawn) shift; cmd_spawn "$@" ;;
  merge) shift; cmd_merge "$@" ;;
  list|status) shift; cmd_list "$@" ;;
  *) usage ;;
esac
