# agent-worktrees

A small, working teaching example: how to run several LLM coding agents
against the same repository *at the same time*, without them stepping on
each other, using `git worktree`.

## The problem

If two agents share one checkout, they fight over the same working
directory:

```
agent A: git checkout feature-a && edit files...
agent B: git checkout feature-b   # <- yanks the working directory out from
                                   #    under agent A mid-edit
```

There is exactly one working directory and one `HEAD` per clone. Whichever
agent runs `git checkout` last wins, and the other agent's uncommitted edits
are now sitting on the wrong branch, or vanish, or collide with the
in-progress edits of whoever else is running. Running agents one at a time
avoids this, but then you're not actually running them in parallel.

## The fix: `git worktree`

```
git worktree add <path> -b <branch>
```

This checks out `<branch>` into `<path>` as a **second, fully independent
working directory and index**, while both worktrees still share the same
underlying `.git` object database (commits, blobs, trees, refs). Concretely:

- Each worktree has its own `HEAD`, its own staging area, its own files on
  disk. `git checkout` in one worktree has zero effect on any other.
- Two agents can each be mid-edit, mid-commit, even mid-`git status`, in
  their own worktrees, at the exact same instant, with no locking and no
  coordination required.
- Because objects are shared, this costs almost nothing extra on disk (no
  second full clone) and every worktree's commits are immediately visible
  as ordinary branches to every other worktree, including the main one.
- When an agent is done, its worktree is just an ordinary branch. You review
  it, merge it into `main` like any other branch, and delete the worktree.

That's the entire trick. This repo wraps it in three small scripts so you
can see it happen instead of just reading about it.

## Layout

```
manager.sh   the tool: spawn / merge / list
demo.sh      spawns two agents at once on independent sample tasks
sandbox/     scratch directory the demo agents are told to edit
.worktrees/  where spawned worktrees live (gitignored, never committed)
```

## `manager.sh`

### `manager.sh spawn <slug> "<task description>"`

```
git worktree add .worktrees/<slug> -b agent/<slug> main
cd .worktrees/<slug>
claude -p "<task prompt>" --permission-mode bypassPermissions
```

Creates a new worktree at `.worktrees/<slug>` on a new branch
`agent/<slug>` cut from `main`, then runs the `claude` CLI inside it in
non-interactive print mode (`-p`) with the task description. The agent is
instructed to commit its own work on that branch when done. Output is
streamed to your terminal and also saved to `.worktrees/<slug>.log`.

`spawn` does **not** merge anything. The branch and worktree are left in
place afterward so you can inspect the diff before deciding to merge it.

Note on permissions: `--permission-mode bypassPermissions` lets the agent
run tools (edit files, run `git commit`, etc.) without stopping to ask,
which is what makes unattended dispatch possible. This is safe here because
the agent's `cwd` is its own disposable worktree under `.worktrees/`, which
is gitignored and isolated from your primary checkout - review the diff
before merging, same as you would review any PR.

### `manager.sh merge <slug>`

```
git merge --no-ff agent/<slug>
git worktree remove .worktrees/<slug>
git branch -d agent/<slug>
```

Merges the worker's branch into `main`, then removes the worktree and
deletes the branch. Must be run from the repo root while it's checked out
on `main` (this is a normal merge - it moves `main`'s `HEAD`, so it needs
`main`'s own working directory to do that in). Refuses to merge if the
worktree still has uncommitted changes.

### `manager.sh list`

```
git worktree list --porcelain
git for-each-ref refs/heads/agent/*
```

Shows every `agent/*` worktree and branch: whether its worktree has
uncommitted changes, and whether it's already merged into `main`. Also
catches "orphan" branches whose worktree directory was removed by hand.

## `demo.sh`

Spawns two agents concurrently on genuinely independent tasks - one writes
`sandbox/haiku.txt`, the other writes `sandbox/fun-fact.txt` - so you can
watch them run at the same time with zero risk of collision, then merges
both back into `main` in turn.

Run it from a clean `main`:

```
./demo.sh
```

What you'll see, in order:

1. Two `git worktree add` calls, creating `.worktrees/haiku` (branch
   `agent/haiku`) and `.worktrees/fact` (branch `agent/fact`) off `main`.
2. Two `claude -p ...` processes started in the background, one per
   worktree, running concurrently - their output interleaves in your
   terminal because they really are running at the same time.
3. Each agent commits its own file on its own branch.
4. `manager.sh list`, showing both branches as `clean` / `outstanding`.
5. `manager.sh merge haiku` then `manager.sh merge fact`: each merge, then
   `git worktree remove`, then `git branch -d`.
6. A final `manager.sh list` (empty - nothing outstanding) and `git log
   --graph`, showing both merge commits and a repo with no leftover
   worktrees or branches.

`demo.sh` is idempotent: if you run it twice, it first tears down any
`haiku`/`fact` worktree or branch left over from a previous run.

## Try it yourself

```
./manager.sh spawn greeting "Create sandbox/hello.txt containing a friendly one-line greeting, and commit it."
./manager.sh list
git -C .worktrees/greeting diff main..agent/greeting   # review before merging
./manager.sh merge greeting
./manager.sh list
```

## Requirements

- `git` with worktree support (any reasonably recent git).
- The `claude` CLI installed and authenticated (`claude --version` should
  work). No other setup - clone this repo and run `./demo.sh`.
