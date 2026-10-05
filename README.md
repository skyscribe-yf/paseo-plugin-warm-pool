# warm-pool

Routes new Paseo **worktree** workspaces into persistent pooled slots so dependency trees are
reused instead of reinstalled on every run.

```
my-checkout          ← the checkout (unchanged)
 ├── [lane-a]             ← slot workspaces, filed under the same project
 ├── [lane-b]
 └── [lane-c]
```

## Why

Paseo allocates a disposable worktree per run (`~/.paseo/worktrees/<hash>/<slug>`) and bumps the
path whenever it already exists, so it never reuses one. Two consequences:

1. Every new workspace is a fresh `git checkout` containing only tracked files. `node_modules` and
   `.venv` are ignored, so they are never carried over.
2. `paseo.json`'s `worktree.setup` runs in that new directory, so `npm install` / `uv sync` run
   again — on a typical web + Python repo that is roughly 145 MB of work per workspace.

This plugin intercepts `workspace.create` and hands out a slot from a pool anchored on the
repository's **shared git directory** (`<repo>/.git/wt-pool/pool/<slot>`). The anchor resolves to
the same path from the main checkout and from any worktree of that repo, and differs between
unrelated repositories — so reuse works while isolation is preserved.

## Setup

The claim protocol ships with this repository under [`scripts/`](scripts/) and works standalone —
see [`scripts/README.md`](scripts/README.md) for the full contract. Point the plugin at that
directory:

```bash
cp -r scripts ~/.paseo/warm-pool-scripts
paseo reload
```

Resolution order:

1. `WARM_POOL_SCRIPTS` environment variable
2. `<repo>/.git/wt-pool-scripts/` inside the repository being served
3. `~/.paseo/warm-pool-scripts/`

The file fallbacks matter. Paseo forks plugin children without an explicit `env`, so they inherit
the **daemon's** environment — and a desktop-managed daemon does not inherit your shell's. A value
exported in your terminal is invisible to the plugin after a daemon restart.

Without any of these, every workspace silently falls back to a normal managed worktree — stock
Paseo behaviour, not an error.

## Behaviour

| Situation | Result |
| --- | --- |
| Free slot | Claimed; workspace cwd becomes the slot |
| All slots busy or dirty | Falls back to a normal managed worktree, with a warning in `paseo plugin logs` |
| Not a git checkout | Request left untouched |
| `isolation: "local"` request | Left untouched (already reuse-friendly) |
| Slot has uncommitted work | Skipped as dirty; never silently overwritten |
| Run already inside the slot it asked for | Refused, exit `4` — two lanes in one directory would race |

Archiving a workspace releases its slot automatically, which is what lets the next run reuse it.
Slots themselves survive archiving on purpose: deleting them is exactly what forces a reinstall.

Slots are **flat siblings**, never nested. A run executing inside `lane-a` that needs its own lane
gets a different slot, never a subdirectory of its own.

## Display

Slot workspaces keep the originating checkout's project, so the sidebar nests them under it instead
of scattering one project per slot:

```
my-checkout          ← the checkout
 ├── pool/lane-a
 ├── pool/lane-b
 └── pool/lane-c
```

This works because the hook carries the checkout's `projectId` through to the creation request.
Without it Paseo falls back to `basename(cwd)` — which for a slot is `lane-a` — and registers a
separate project per slot.

The plugin deliberately sets **no** title. Paseo lets an agent call `rename_workspace` to attach a
generated description, and that replaces `title` wholesale, so a lane marker planted there would be
wiped by the first turn. Leaving `title` null keeps the derived branch name until the agent renames
it, and lets the generated description land cleanly afterwards.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `WARM_POOL_SLOTS` | `lane-a` … `lane-h` (8) | Concurrency cap per repository. `lane-a`..`lane-c` are commonly shared with an agent skill that uses them for its own lanes; `lane-d`..`lane-h` are this plugin's capacity. Both draw from the same pool. |
| `WARM_POOL_ENABLED` | `1` | `0` disables the hook and restores stock behaviour |

```bash
WARM_POOL_SLOTS="lane-a lane-b lane-c lane-d lane-e lane-f lane-g lane-h lane-i lane-j" paseo reload
```

Each slot is a full checkout with its own `.venv`. `node_modules` costs far less than it appears:
once pnpm's global store (`~/.local/share/pnpm/store`) is warm, a later install in a fresh
directory adds essentially **zero** new disk, measured with `df` before and after — the files are
hardlinked from the store rather than copied. That holds while store and checkout stay on one
filesystem; across devices pnpm falls back to copying and the saving disappears. Python virtualenvs
never share — `pyvenv.cfg` and `bin/activate` hardcode an absolute `VIRTUAL_ENV` — so budget roughly
250 MB per slot for `.venv` alone.

## Locking

Claiming delegates to `scripts/pool-take.sh` rather than reimplementing the protocol, so the plugin
and any other caller share one implementation. That script:

- treats a claim as busy until `POOL_STALE_SEC` (default 6h) has elapsed, then steals it — age, not
  PID liveness, because the shell that took the claim exits within seconds;
- refuses a slot with uncommitted work, and keeps the lock so a later run cannot silently discard it;
- refuses to hand a run the slot it is already standing in (exit `4`);
- rolls its own lock back if slot creation fails, so a failure cannot wedge the pool.

## The workspace panel

A **Warm Pool** tab beside agents, terminals and files shows each slot's branch, disk usage, lock
age and dirty state, with Claim / Release buttons.

## Notes

- The hook never runs a package install; dependency setup stays the agent's job.
- **Never `mv` a slot directory to relocate it.** Git bookkeeping breaks in two places at once — the
  absolute path inside `.git/worktrees/<name>/gitdir` and the stale entry `git worktree prune`
  removes — and `git worktree repair` alone does *not* fix it. Moved slots turn `prunable`, after
  which branch-based lookups can return the abandoned path. Relocate with a migration script that
  rewrites `gitdir` per slot.
- A slot directory can be deleted while its branch survives. That is fine: creation re-uses the
  existing branch instead of failing with "branch already exists".