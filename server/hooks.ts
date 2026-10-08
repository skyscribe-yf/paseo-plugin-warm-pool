import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import type { PluginServerContext } from "@getpaseo/plugin/server";

import { poolScriptsDir } from "./scripts-dir";

const execFileAsync = promisify(execFile);

/**
 * Slots the plugin manages, claimed in order.
 *
 * Eight concurrent workspaces per repository. `lane-a`..`lane-c` are shared with
 * the implementer skill, which uses them for its own lanes; `lane-d`..`lane-h`
 * are this plugin's own capacity. Both draw from the same pool, so the total is
 * one shared set of slots rather than two competing pools.
 *
 * Raise `WARM_POOL_SLOTS` for more. The pool never grows past this list, so the
 * limit is explicit and bounded rather than emergent.
 */
const DEFAULT_SLOTS = [
  "lane-a",
  "lane-b",
  "lane-c",
  "lane-d",
  "lane-e",
  "lane-f",
  "lane-g",
  "lane-h",
];

function slotNames(): string[] {
  const raw = process.env.WARM_POOL_SLOTS;
  if (!raw) return [...DEFAULT_SLOTS];
  const parsed = raw
    .split(/[,\s]+/)
    .map((s) => s.trim())
    .filter(Boolean);
  return parsed.length > 0 ? parsed : [...DEFAULT_SLOTS];
}

/**
 * Absolute pool anchor for a checkout, e.g. `/repo.wt-pool`.
 *
 * Mirrors `wt_anchor_dir` in the implementer skill's `wt-anchor.sh` — the two must
 * agree on where slots live or the plugin and the skill end up pointing at different
 * pools. Keep the comments there in sync when changing either side.
 *
 * The anchor is a sibling of the repo rather than a directory inside `.git` because
 * Paseo's workspace-git-service observes `git-common-dir` as its file-observer root
 * and `linux.js` caps that at `MAX_WATCHED_DIRECTORIES = 5000`. Full checkout slots
 * (with node_modules/.venv) push one pool into the tens of thousands of directories,
 * blow the cap, and degrade git metadata to polling.
 */
async function anchorOf(cwd: string): Promise<string | null> {
  try {
    const { stdout } = await execFileAsync(
      "git",
      ["rev-parse", "--path-format=absolute", "--git-common-dir"],
      { cwd },
    );
    const common = stdout.trim();
    // A bare repo has no `.git` suffix and has no usable pool.
    if (!common.endsWith("/.git") && !common.endsWith("\\.git")) return null;
    // Strip the `/` TOO. `slice(0, -".git".length)` leaves a trailing slash, which would
    // yield `<repo>/.wt-pool` (inside the checkout) instead of the sibling `<repo>.wt-pool`.
    const repoRoot = common.replace(/[/\\]\.git$/, "");
    return `${repoRoot}.wt-pool`;
  } catch {
    return null;
  }
}

/**
 * Anchor and main checkout for a slot path, tolerating an already-removed slot.
 *
 * A slot lives at `<repo>.wt-pool/pool/<slot>`, so the anchor can be recovered by
 * string surgery even when the worktree is gone — which is the normal state by the
 * time `workspace.archived` fires. The repo path is the anchor with the `.wt-pool`
 * suffix stripped, which is why the anchor has to stay a sibling directory rather
 * than moving somewhere opaque like a hashed cache root.
 */
function parseSlotPath(path: string): { anchor: string; repo: string; slot: string } | null {
  const parts = path.split("/").filter(Boolean);
  const poolIndex = parts.lastIndexOf("pool");
  if (poolIndex < 1 || poolIndex + 2 !== parts.length) return null;
  const anchorDir = parts[poolIndex - 1] ?? "";
  if (!anchorDir.endsWith(".wt-pool")) return null;
  const anchor = `/${parts.slice(0, poolIndex).join("/")}`;
  return {
    anchor,
    // Strip the suffix off the FULL anchor, not off `anchorDir`. `anchorDir` is only the
    // last path segment, so deriving repo from it yields `/mind-shield-ws-1` instead of
    // `/home/.../srcs/mind-shield-ws-1` — which never matches a projectRootPath, leaving
    // the slot without a projectId and letting Paseo name a project after `basename(cwd)`.
    repo: anchor.slice(0, -".wt-pool".length),
    slot: parts[poolIndex + 1]!,
  };
}

/**
 * Claim the first free slot via the skill's `pool-take.sh`.
 *
 * Reusing the script keeps one locking implementation shared with the
 * implementer skill rather than a second one that drifts from it.
 */
async function claimSlot(cwd: string, label: string): Promise<{ path: string; slot: string } | null> {
  const dir = poolScriptsDir();
  if (!dir) return null;
  const script = join(dir, "pool-take.sh");
  if (!existsSync(script)) return null;
  for (const slot of slotNames()) {
    try {
      const { stdout } = await execFileAsync(script, [slot, label], {
        cwd,
        // Never run a package install from a hook.
        env: { ...process.env, WT_POOL_BOOTSTRAP: "0" },
        maxBuffer: 8 * 1024 * 1024,
      });
      const path = stdout.trim();
      if (path.length > 0 && existsSync(path)) return { path, slot };
    } catch {
      // Exit 2 = busy, 3 = dirty. Try the next slot either way.
    }
  }
  return null;
}

async function releaseSlot(cwd: string, slot: string): Promise<void> {
  const dir = poolScriptsDir();
  if (!dir) return;
  const script = join(dir, "pool-release.sh");
  if (!existsSync(script)) return;
  try {
    await execFileAsync(script, [slot], { cwd, maxBuffer: 4 * 1024 * 1024 });
  } catch {
    // Best effort; a stale lock self-heals after the stale threshold.
  }
}

/**
 * Remember which slot each workspace claimed.
 *
 * Without this the lock outlives its workspace, the slot looks permanently busy,
 * and every new workspace opens another slot instead of reusing a warm one —
 * which reintroduces exactly the waste this plugin exists to remove.
 */
type SlotMapping = Record<string, { slot: string; repo: string }>;

function readMapping(anchor: string): SlotMapping {
  try {
    return JSON.parse(readFileSync(join(anchor, "workspace-slots.json"), "utf8")) as SlotMapping;
  } catch {
    return {};
  }
}

function writeMapping(anchor: string, mapping: SlotMapping): void {
  try {
    writeFileSync(join(anchor, "workspace-slots.json"), `${JSON.stringify(mapping, null, 2)}\n`);
  } catch {
    // Best effort: a missing mapping only costs a stale lock.
  }
}

/**
 * Workspace display name for a pooled slot.
 *
 * Left unset on purpose. Paseo lets an agent later call `rename_workspace` to attach an
 * AI-generated description, and that call **replaces** `title` wholesale. A lane marker planted in
 * `title` would therefore be wiped by the first turn. The slot identity instead rides on the
 * derived display name (the branch, `pool/<slot>`), which reconciliation keeps re-deriving from
 * git and never overwrites.
 *
 * Leaving `title` null is what makes the generated description survive intact.
 */

/**
 * Find the project whose root is exactly this checkout, so a slot workspace can be filed under the
 * checkout's project instead of becoming its own.
 *
 * Paseo derives a project from `basename(cwd)` when no `projectId` is supplied, which for a slot is
 * just `lane-a`. That registers one project per slot and scatters the sidebar. Passing the
 * originating project keeps slots grouped under `my-checkout`.
 */
async function projectIdForCheckout(
  paseo: { projects: { list: () => Promise<{ projects: { projectId: string; projectRootPath: string }[] }> } },
  checkoutRoot: string,
): Promise<string | undefined> {
  try {
    const { projects } = await paseo.projects.list();
    const target = checkoutRoot.endsWith("/") ? checkoutRoot.slice(0, -1) : checkoutRoot;
    return projects.find((p) => p.projectRootPath === target || p.projectRootPath.endsWith(`/${target}`))
      ?.projectId;
  } catch {
    return undefined;
  }
}

function describeLabel(req: {
  title?: string;
  firstAgentContext?: { prompt?: string };
}): string {
  const title = req.title?.trim();
  if (title) return title.slice(0, 60);
  const prompt = req.firstAgentContext?.prompt?.trim();
  if (prompt) return prompt.split("\n")[0]!.slice(0, 60);
  return "paseo workspace";
}

/**
 * Re-file a request that already targets a pool slot under the slot's checkout.
 *
 * The implementer skill claims a slot with `pool-take.sh` and then adopts that
 * existing directory as a workspace. That path never reaches the worktree branch
 * below, and without a `projectId` Paseo derives the project from `basename(cwd)`
 * — `lane-a` — registering one project per slot in the sidebar. Injecting the
 * checkout's project keeps slots nested under `my-checkout` however the workspace
 * is created.
 */
async function fileSlotDirectorySource(
  paseo: {
    projects: { list: () => Promise<{ projects: { projectId: string; projectRootPath: string }[] }> };
  },
  source: { kind: "directory"; path: string; projectId?: string },
): Promise<{ kind: "directory"; path: string; projectId?: string } | undefined> {
  if (source.projectId) return undefined;
  const parsed = parseSlotPath(source.path);
  if (!parsed || !slotNames().includes(parsed.slot)) return undefined;
  const projectId = await projectIdForCheckout(paseo, parsed.repo);
  if (!projectId) return undefined;
  console.log(`[warm-pool] filed ${source.path} under project ${projectId}`);
  return { ...source, projectId };
}

/**
 * Register the daemon-side worktree hooks.
 *
 * `workspace.create` fires before Paseo branches on `source.kind`, so returning
 * a `directory` source swaps the disposable worktree for a persistent pooled
 * one. A `directory` source must already exist, which is why the slot is claimed
 * inside the hook.
 */
export function registerWorktreeHooks(server: PluginServerContext): () => void {
  if (process.env.WARM_POOL_ENABLED === "0") return () => {};

  const removeBefore = server.before("workspace.create", async ({ request }, ctx) => {
    // A request that already points at a pool slot keeps its directory; only the
    // project filing needs fixing. Covers callers that adopt a pre-claimed slot
    // instead of asking for a worktree (the implementer skill's lane flow).
    if (request.source.kind === "directory") {
      const source = await fileSlotDirectorySource(ctx.paseo, request.source);
      return source ? { ...request, source } : undefined;
    }

    // Only explicit worktree requests need redirecting to a slot. Directory
    // requests already point at the directory they want.
    if (request.source.kind !== "worktree") return undefined;

    const cwd = request.source.cwd;
    if (!cwd) return undefined;
    const anchor = await anchorOf(cwd);
    if (!anchor) return undefined;

    const label = describeLabel(request);
    const claimed = await claimSlot(cwd, label);
    if (!claimed) {
      console.warn(
        `[warm-pool] no free slot for "${label}" (${cwd}); leaving the managed worktree in place`,
      );
      return undefined;
    }

    // Prefer the request's own project, else look the checkout's project up. Without one
    // Paseo infers the project from the slot's own path (`basename` → `lane-a`), which
    // registers every slot as its own project instead of nesting it under the checkout.
    const repo = parseSlotPath(claimed.path)?.repo;
    const projectId =
      request.source.projectId ?? (repo ? await projectIdForCheckout(ctx.paseo, repo) : undefined);

    console.log(
      `[warm-pool] "${label}" -> ${claimed.path} (${claimed.slot}, project ${projectId ?? "unresolved"})`,
    );
    return {
      ...request,
      source: { kind: "directory", path: claimed.path, projectId },
      // Only honour a title the caller already set. Left unset otherwise so the slot shows its
      // derived branch name (`pool/<slot>`) and an agent's later `rename_workspace` lands cleanly
      // instead of overwriting a plugin-planted prefix.
      ...(request.title?.trim() ? { title: request.title.trim() } : {}),
    };
  });

  // The workspace id is assigned after the before hook runs, so the mapping has
  // to be recorded here. The workspace cwd is the slot we just handed out.
  const removeCreated = server.on("workspace.created", async (event) => {
    const workspace = event.workspace;
    const anchor = await anchorOf(workspace.cwd);
    if (!anchor) return;
    const mapping = readMapping(anchor);
    if (mapping[workspace.id]) return;
    const slot = basename(workspace.cwd);
    if (!slotNames().includes(slot)) return;
    mapping[workspace.id] = { slot, repo: parseSlotPath(workspace.cwd)?.repo ?? anchor };
    writeMapping(anchor, mapping);
  });

  // Release the slot when its workspace goes away, otherwise the pool fills up
  // with permanently-busy slots and reuse stops.
  const removeArchived = server.on("workspace.archived", async (event) => {
    const workspace = event.workspace;
    // By archive time the slot directory may already be gone, so resolve the
    // anchor from the path string rather than from git.
    const parsed = parseSlotPath(workspace.cwd);
    if (!parsed) return;
    const { anchor, repo, slot } = parsed;
    if (!slotNames().includes(slot)) return;
    await releaseSlot(repo, slot);
    const mapping = readMapping(anchor);
    if (mapping[workspace.id]) {
      delete mapping[workspace.id];
      writeMapping(anchor, mapping);
    }
    console.log(`[warm-pool] released ${slot} for archived ${workspace.id}`);
  });

  return () => {
    removeBefore();
    removeArchived();
  };
}