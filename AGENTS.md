# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## What this is

A teaching repo + working tool for running multiple `claude` CLI agents in parallel via
`git worktree`, one branch/worktree per agent, merged back into `main` when done. See
README.md for the concept explanation and full walkthrough.

## Layout

- `manager.sh` - the whole tool: `spawn <slug> "<task>"`, `merge <slug>`, `list`. Read it
  top to bottom before changing behavior; it's short and each subcommand is self-contained.
- `demo.sh` - spawns two agents concurrently on independent `sandbox/` files, then merges both.
- `.worktrees/` - where spawned worktrees land (gitignored; never commit anything here).
- `sandbox/` - scratch target for demo/example agent tasks.

## Conventions the scripts assume

- Trunk branch is always `main`. `manager.sh merge` refuses to run unless the repo root's
  current branch is `main` (a normal merge needs `main`'s own working directory).
- Worker branches are always named `agent/<slug>`, worktrees always at `.worktrees/<slug>`.
- Agents are dispatched with `claude -p ... --permission-mode bypassPermissions` so they can
  edit files and commit unattended - this is safe only because each agent's cwd is its own
  disposable, gitignored worktree, isolated from the primary checkout.

## Testing changes to manager.sh / demo.sh

There is no test suite. Validate changes by cloning the repo into a scratch directory
(checked out on `main`), running `./demo.sh` there, and confirming: both agents commit
independently with no file/git-state collision, `list` reflects state correctly at each
stage, and after both merges the repo is clean (no dangling worktrees or `agent/*` branches).
Do not run `demo.sh` against the primary checkout you're editing in.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
