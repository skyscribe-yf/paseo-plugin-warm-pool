import type { PluginClientContext } from "@getpaseo/plugin/client";

import contributePanel from "./client/pool-panel";

export default function contribute(client: PluginClientContext) {
  return contributePanel(client);
}