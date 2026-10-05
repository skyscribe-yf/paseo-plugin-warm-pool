import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync, readdirSync, statSync, readFileSync } from "node:fs";
import { join } from "node:path";

const execFileAsync = promisify(execFile);

/**
 * Resolve the pool anchor for a repository.
 *
 * The anchor is derived from the *shared git directory*, not the working
 * directory. That is the whole point: Paseo hands every agent a fresh
 * disposable worktree (`~/.paseo/worktrees/<hash>/<slug>`) and bumps the path
 * whenever it already exists, so anything anchored to `$PWD` dies with the run.
 * The shared git dir is identical for the main checkout and every worktree of
 * the same repository, and distinct for unrelated repositories — exactly the
 * reuse/isolation split we need.
 *
 * Keep this in sync with `~/.agents/skills/implementer/wt-anchor.sh`.
 */
export async function resolveAnchor(cwd: string): Promise<{
  gitCommonDir: string;
  repoRoot: string;
  anchor: string;
  pool: string;
  locks: string;
}> {
  let gitCommonDir: string;
  try {
    const { stdout } = await execFileAsync(
      "git",
      ["rev-parse", "--path-format=absolute", "--git-common-dir"],
      { cwd },
    );
    gitCommonDir = stdout.trim();
  } catch {
    // git older than 2.31 has no --path-format=absolute; resolve manually.
    const { stdout } = await execFileAsync("git", ["rev-parse", "--git-common-dir"], { cwd });
    gitCommonDir = join(cwd, stdout.trim());
  }

  // A bare repo's common dir is the repo itself; otherwise it is `<root>/.git`.
  const repoRoot = gitCommonDir.endsWith("/.git") || gitCommonDir.endsWith("\\.git")
    ? gitCommonDir.slice(0, -5)
    : gitCommonDir;

  const anchor = join(gitCommonDir, "wt-pool");
  return {
    gitCommonDir,
    repoRoot,
    anchor,
    pool: join(anchor, "pool"),
    locks: join(anchor, "locks"),
  };
}

/**
 * Directory holding `pool-take.sh` / `pool-release.sh`.
 *
 * Not shipped with this plugin — the scripts come from your own agent tooling — so there is no
 * default. Callers surface a clear error when this is unset.
 */
import { poolScriptsDir } from "./scripts-dir";

export { poolScriptsDir };

async function git(args: string[], cwd: string): Promise<string> {
  const { stdout } = await execFileAsync("git", args, { cwd, maxBuffer: 8 * 1024 * 1024 });
  return stdout;
}

/** Branch checked out in a worktree, or null. */
async function branchOf(path: string): Promise<string | null> {
  try {
    const b = (await git(["branch", "--show-current"], path)).trim();
    return b.length > 0 ? b : null;
  } catch {
    return null;
  }
}

/** True when git's worktree list still tracks this path. */
async function trackedByGit(repoRoot: string, path: string): Promise<boolean> {
  try {
    const out = await git(["worktree", "list", "--porcelain"], repoRoot);
    const paths = out
      .split("\n")
      .filter((l) => l.startsWith("worktree "))
      .map((l) => l.slice("worktree ".length).trim());
    return paths.includes(path);
  } catch {
    return false;
  }
}

async function isDirty(path: string): Promise<boolean> {
  try {
    const out = await git(["status", "--porcelain"], path);
    return out.trim().length > 0;
  } catch {
    return false;
  }
}

/** Directory size in bytes, bounded so a huge node_modules cannot hang the RPC. */
function dirBytes(path: string): number {
  let total = 0;
  const stack = [path];
  while (stack.length > 0) {
    const cur = stack.pop() as string;
    let entries: string[];
    try {
      entries = readdirSync(cur);
    } catch {
      continue;
    }
    for (const name of entries) {
      const full = join(cur, name);
      try {
        const st = statSync(full);
        if (st.isDirectory()) {
          stack.push(full);
        } else {
          total += st.size;
        }
      } catch {
        // Broken symlink or a race with cleanup; skip it.
      }
    }
  }
  return total;
}

function readClaim(lockPath: string): { claim: string | null; ageSeconds: number | null } {
  const claimFile = join(lockPath, "claim");
  try {
    const claim = readFileSync(claimFile, "utf8").trim();
    const st = statSync(lockPath);
    return { claim, ageSeconds: Math.max(0, Math.round((Date.now() - st.mtimeMs) / 1000)) };
  } catch {
    return { claim: null, ageSeconds: null };
  }
}

/** Existing slot directories, sorted. */
export function listSlotDirs(pool: string): string[] {
  try {
    return readdirSync(pool, { withFileTypes: true })
      .filter((e) => e.isDirectory() && !e.name.startsWith("."))
      .map((e) => e.name)
      .sort();
  } catch {
    return [];
  }
}

/** Existing lock directories, sorted. */
export function listLockDirs(locks: string): string[] {
  try {
    return readdirSync(locks, { withFileTypes: true })
      .filter((e) => e.isDirectory() && !e.name.startsWith("."))
      .map((e) => e.name.replace(/\.lock$/, ""))
      .sort();
  } catch {
    return [];
  }
}

export async function inspect(cwd: string) {
  const anchorPaths = await resolveAnchor(cwd);
  const slotNames = listSlotDirs(anchorPaths.pool);
  const lockNames = listLockDirs(anchorPaths.locks);

  const slots = await Promise.all(
    slotNames.map(async (name) => {
      const path = join(anchorPaths.pool, name);
      const lock = readClaim(join(anchorPaths.locks, `${name}.lock`));
      return {
        name,
        path,
        exists: existsSync(path),
        branch: await branchOf(path),
        trackedByGit: await trackedByGit(anchorPaths.repoRoot, path),
        bytes: dirBytes(path),
        dirty: await isDirty(path),
        lockedForSeconds: lock.ageSeconds,
        claim: lock.claim,
      };
    }),
  );

  const locks = lockNames.map((name) => {
    const { claim, ageSeconds } = readClaim(join(anchorPaths.locks, `${name}.lock`));
    return { name, ageSeconds: ageSeconds ?? 0, claim };
  });

  return {
    anchor: anchorPaths.anchor,
    gitCommonDir: anchorPaths.gitCommonDir,
    repoRoot: anchorPaths.repoRoot,
    slots,
    locks,
  };
}

/**
 * Claim a slot by invoking the skill's `pool-take.sh`.
 *
 * Delegating to the script keeps one locking implementation shared with the
 * implementer skill; a second implementation here would drift from it.
 */
export async function claim(
  cwd: string,
  slot: string,
  task: string,
  base?: string,
): Promise<{ status: "claimed" | "busy" | "dirty" | "error"; path: string | null; message: string }> {
  const dir = poolScriptsDir();
  if (!dir) {
    return {
      status: "error",
      path: null,
      message: "WARM_POOL_SCRIPTS is not set. Point it at the directory holding pool-take.sh.",
    };
  }
  const script = join(dir, "pool-take.sh");
  if (!existsSync(script)) {
    return {
      status: "error",
      path: null,
      message: `pool-take.sh not found at ${script}. Set WARM_POOL_SCRIPTS to the directory holding it.`,
    };
  }

  const env = { ...process.env };
  if (base) env.POOL_SLOT_BASE = base;
  // Skip the dependency bootstrap in the daemon: the plugin should not run a
  // package install behind the user's back. Deps are handled by the agent.
  env.WT_POOL_BOOTSTRAP = "0";

  try {
    const { stdout, stderr } = await execFileAsync(script, [slot, task], {
      cwd,
      env,
      maxBuffer: 8 * 1024 * 1024,
    });
    const out = stdout.trim();
    return { status: "claimed", path: out, message: stderr.trim() || `claimed ${slot}` };
  } catch (err) {
    const e = err as { code?: number | string; stdout?: string; stderr?: string };
    const message = (e.stderr ?? e.stdout ?? String(err)).trim();
    // 2 = busy (healthy claim), 3 = dirty / unusable slot.
    if (e.code === 2) return { status: "busy", path: null, message };
    if (e.code === 3) return { status: "dirty", path: null, message };
    return { status: "error", path: null, message };
  }
}

export async function release(
  cwd: string,
  slot: string,
): Promise<{ released: boolean; message: string }> {
  const dir = poolScriptsDir();
  if (!dir) {
    return { released: false, message: "WARM_POOL_SCRIPTS is not set" };
  }
  const script = join(dir, "pool-release.sh");
  if (!existsSync(script)) {
    return { released: false, message: `pool-release.sh not found at ${script}` };
  }
  try {
    const { stdout, stderr } = await execFileAsync(script, [slot], { cwd, maxBuffer: 4 * 1024 * 1024 });
    return { released: true, message: (stdout || stderr).trim() };
  } catch (err) {
    const e = err as { stderr?: string };
    return { released: false, message: (e.stderr ?? String(err)).trim() };
  }
}