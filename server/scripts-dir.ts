import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * Resolve the directory holding `pool-take.sh` / `pool-release.sh`.
 *
 * Resolution order:
 *   1. `WARM_POOL_SCRIPTS` environment variable
 *   2. `<repo>/.git/wt-pool-scripts` inside the repository being served
 *   3. `~/.paseo/warm-pool-scripts`
 *
 * The environment variable alone is not enough. Paseo forks plugin children without an explicit
 * `env`, so they inherit the daemon's environment — and a desktop-managed daemon does not inherit
 * your shell's. A value exported in your terminal is therefore invisible to the plugin after a
 * daemon restart. The file fallbacks persist across restarts.
 *
 * The scripts themselves are not shipped with this plugin; they implement the claim protocol and
 * belong to your own agent tooling.
 */
export function poolScriptsDir(cwd?: string): string | null {
  const fromEnv = process.env.WARM_POOL_SCRIPTS?.trim();
  if (fromEnv) return fromEnv;

  if (cwd) {
    const inRepo = join(cwd, ".git", "wt-pool-scripts");
    if (existsSync(join(inRepo, "pool-take.sh"))) return inRepo;
  }

  const inPaseoHome = join(homedir(), ".paseo", "warm-pool-scripts");
  if (existsSync(join(inPaseoHome, "pool-take.sh"))) return inPaseoHome;

  return null;
}