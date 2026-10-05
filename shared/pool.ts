import { defineRpc } from "@getpaseo/plugin";
import { z } from "zod";

/**
 * Pool inspection.
 *
 * Returns the anchored pool layout for a repository so a surface can show slot
 * state. Read-only: this RPC never creates, resets, or removes anything.
 */
export const poolInspect = defineRpc({
  name: "warm-pool.inspect",
  input: z.object({
    /** Repository path (main checkout or any worktree of it). */
    cwd: z.string().min(1),
  }),
  output: z.object({
    /** Absolute pool anchor, e.g. /repo/.git/wt-pool. */
    anchor: z.string(),
    /** Per-repo identity used for isolation decisions (the shared git dir). */
    gitCommonDir: z.string(),
    /** Repository root derived from the shared git dir. */
    repoRoot: z.string(),
    slots: z.array(
      z.object({
        name: z.string(),
        path: z.string(),
        exists: z.boolean(),
        /** Checked-out branch, or null when the slot does not exist / is bare. */
        branch: z.string().nullable(),
        /** True when git still tracks the slot (not pruned). */
        trackedByGit: z.boolean(),
        /** Size on disk in bytes, 0 when the slot is absent. */
        bytes: z.number().int().nonnegative(),
        dirty: z.boolean(),
        /** Lock age in seconds; null when the slot is not claimed. */
        lockedForSeconds: z.number().int().nonnegative().nullable(),
        /** Contents of the lock claim file, when present. */
        claim: z.string().nullable(),
      }),
    ),
    locks: z.array(
      z.object({
        name: z.string(),
        ageSeconds: z.number().int().nonnegative(),
        claim: z.string().nullable(),
      }),
    ),
  }),
});

/**
 * Claim a slot through the shared pool scripts.
 *
 * The daemon-side handler shells out to `pool-take.sh` so the plugin and the
 * implementer skill use exactly one implementation of the locking protocol.
 * Exit codes follow the script: 0 claimed, 2 busy, 3 dirty or unusable.
 */
export const poolClaim = defineRpc({
  name: "warm-pool.claim",
  input: z.object({
    cwd: z.string().min(1),
    slot: z.string().min(1),
    task: z.string().min(1),
    /** Base ref used only when the slot has to be created. */
    base: z.string().min(1).optional(),
  }),
  output: z.object({
    status: z.enum(["claimed", "busy", "dirty", "error"]),
    /** Absolute slot worktree path when claimed. */
    path: z.string().nullable(),
    message: z.string(),
  }),
});

/** Release a previously claimed slot. Idempotent. */
export const poolRelease = defineRpc({
  name: "warm-pool.release",
  input: z.object({
    cwd: z.string().min(1),
    slot: z.string().min(1),
  }),
  output: z.object({
    released: z.boolean(),
    message: z.string(),
  }),
});