import type { PluginServerContext } from "@getpaseo/plugin/server";

import { registerWorktreeHooks } from "./server/hooks";
import { claim, inspect, release } from "./server/pool";
import { poolClaim, poolInspect, poolRelease } from "./shared/pool";

export default function contribute(server: PluginServerContext) {
  server.handle(poolInspect, ({ cwd }) => inspect(cwd));
  server.handle(poolClaim, ({ cwd, slot, task, base }) => claim(cwd, slot, task, base));
  server.handle(poolRelease, ({ cwd, slot }) => release(cwd, slot));

  const removeHook = registerWorktreeHooks(server);

  return () => {
    removeHook();
  };
}