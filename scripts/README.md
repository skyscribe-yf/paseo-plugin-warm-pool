# Pool scripts

The claim protocol the plugin shells out to. They are also usable on their own, from any agent or
script, without the Paseo plugin.

> **Upstream:** [`skyscribe-yf/implementer-skill`](https://github.com/skyscribe-yf/implementer-skill)
> — `scripts/` there is the source of truth. This directory is a vendored snapshot so the plugin
> installs from a single clone. If you change the scripts, change them upstream and re-copy, or the
> two will drift.

## Why they exist

A fresh git worktree costs a checkout plus a full dependency bootstrap. Reusing one keeps its
ignored `node_modules` / `.venv` in place, so the dependency step becomes a no-op or a hardlink
refresh instead of a full install.

The catch is *where to put the worktrees*. Anything anchored to the working directory dies with
the session: harnesses hand each run a disposable worktree (Paseo uses
`~/.paseo/worktrees/<hash>/<slug>` and bumps the path whenever it exists), so a pool under `$PWD`
cannot survive a single run, and a lock file written there is invisible to the next one.

These scripts anchor on `git rev-parse --path-format=absolute --git-common-dir` instead:

| Entry point into the same repo | Anchor | Shared? |
| --- | --- | --- |
| main checkout | `<repo>/.git/wt-pool` | ✅ |
| any worktree of that repo | `<repo>/.git/wt-pool` | ✅ |
| a different clone of the same remote | that clone's own `.git` | ❌ isolated, lock included |

`.git/` needs no `.gitignore` entry, is never committed, never leaks through rsync, and disappears
with the repository.

## Layout

```
<repo>/.git/wt-pool/
├── pool/
│   ├── lane-a/            ← a worktree, kept warm across runs
│   └── lane-b/
└── locks/
    ├── lane-a.lock/claim  ← atomic claim; the directory is the lock
    └── lane-b.lock/
```

Slots are **flat siblings**, never nested. A run executing inside `lane-a` that needs its own lane
gets a different slot. Asking for `lane-a` from inside `lane-a` is refused (exit `4`) — two lanes
writing one directory is how duplicate-writer incidents start.

## Scripts

| Script | Purpose |
| --- | --- |
| `wt-anchor.sh` | Resolves the anchor. Source it; do not execute. Provides `wt_anchor_dir`, `wt_pool_dir`, `wt_lock_dir`, `wt_lock_file`, `wt_ensure_dirs`. |
| `wt-pool.sh <branch> [base]` | Create-or-reuse a worktree for `branch`, printing its path on stdout (status goes to stderr). `--print` skips reset and bootstrap; `--self-test` exercises the contract in a temp repo. |
| `pool-take.sh <slot> <task>` | Atomically claim `<slot>`. Prints the path on stdout. |
| `pool-release.sh <slot>` | Release the slot's lock. Idempotent. |
| `wt-migrate-anchor.sh` | One-time move from an older `<toplevel>/.worktrees/pool/` layout. See below. |

### Exit codes — `pool-take.sh`

| Code | Meaning | Do |
| --- | --- | --- |
| `0` | Claimed (created or reused) | use it |
| `2` | Held by a live claim | try another slot, or wait |
| `3` | Slot has uncommitted work, or creation failed | triage by hand |
| `4` | The slot you asked for is the one you are standing in | pick a different slot |

Over-capacity is not an error: when every slot is busy or dirty the caller simply proceeds where it
already is. There is no queue and no blocking wait.

## Usage

```bash
POOL="$HOME/.agents/skills/implementer"      # wherever these live

# Warm a lane before dispatching it (idempotent).
slot=$("$POOL/wt-pool.sh" pool/lane-a origin/master)

# Or let the claim create it on first use.
slot=$("$POOL/pool-take.sh" lane-a "implement issue 1234")

# Hand that path to the worker as its working directory, then release when done.
"$POOL/pool-release.sh" lane-a
```

`WT_POOL_BOOTSTRAP=0` skips the dependency bootstrap entirely. `POOL_SLOT_BASE=<ref>` sets the base
ref used when a slot has to be created (default `origin/master`).

## Locking

A claim is an `mkdir`, so it is atomic. Age decides staleness, never PID liveness: the shell that
wrote `pid=$$` is short-lived, so a PID check reports "dead" within seconds and every lock looks
stealable. A claim older than `POOL_STALE_SEC` (default 6h) is stolen.

A slot with uncommitted work keeps its lock and is reported as dirty rather than being reused —
those changes may be the only surviving copy of an interrupted run. Creation failure rolls the lock
back so a transient error cannot wedge the pool.

## Two things that will bite you

**Never `mv` a slot.** Git tracks a worktree in two places at once — the absolute path inside
`.git/worktrees/<name>/gitdir`, and the admin entry `git worktree prune` cleans up. `git worktree
repair` does **not** fix a moved worktree (it repairs the inverse corruption), so a relocated slot
turns `prunable` and branch-based lookups start returning the abandoned path. Use
`wt-migrate-anchor.sh`, which rewrites `gitdir` per slot and verifies each one.

**Deleting a slot is not the same as losing its branch.** A removed directory leaves the branch
behind, and the next claim re-uses that branch instead of failing with "branch already exists".

## Migrating from an older layout

```bash
"$POOL/wt-migrate-anchor.sh" --dry-run
"$POOL/wt-migrate-anchor.sh"
```

Dependency trees move with the directories, so nothing is reinstalled. The script refuses to
continue if the destination already holds a slot with the same name, since mixing two layouts in
one pool corrupts the bookkeeping.