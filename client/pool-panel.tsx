import type {
  PluginClientContext,
  PluginWorkspacePanelProps,
} from "@getpaseo/plugin/client";
import { useRpc, useWorkspace } from "@getpaseo/plugin/client";
import { useCallback, useMemo, useState } from "react";
import { ActivityIndicator, Pressable, ScrollView, Text, View } from "react-native";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { poolClaim, poolInspect, poolRelease } from "../shared/pool";

function formatBytes(bytes: number): string {
  if (bytes <= 0) return "—";
  const units = ["B", "KB", "MB", "GB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(value >= 10 || unit === 0 ? 0 : 1)} ${units[unit]}`;
}

function formatAge(seconds: number | null): string {
  if (seconds === null) return "";
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.round(seconds / 60)}m`;
  return `${(seconds / 3600).toFixed(1)}h`;
}

function PoolPanel({ theme, layout, workspaceId }: PluginWorkspacePanelProps) {
  const styles = useMemo(
    () => ({
      screen: {
        flex: 1,
        padding: layout.compact ? 16 : 24,
        gap: 12,
        backgroundColor: theme.colors.surface0,
      },
      heading: {
        color: theme.colors.foreground,
        fontSize: layout.compact ? 18 : 22,
        fontWeight: "600" as const,
      },
      muted: { color: theme.colors.foregroundMuted, fontSize: 12 },
      row: {
        flexDirection: "row" as const,
        alignItems: "center" as const,
        gap: 8,
        paddingVertical: 10,
        borderBottomWidth: 1,
        borderBottomColor: theme.colors.border,
      },
      name: { color: theme.colors.foreground, fontSize: 14, fontWeight: "500" as const },
      detail: { color: theme.colors.foregroundMuted, fontSize: 12, flexShrink: 1 },
      pill: {
        paddingHorizontal: 8,
        paddingVertical: 2,
        borderRadius: 6,
        overflow: "hidden" as const,
      },
      pillText: { fontSize: 11, fontWeight: "600" as const },
      button: {
        paddingHorizontal: 12,
        paddingVertical: 6,
        borderRadius: 8,
        backgroundColor: theme.colors.accent,
      },
      buttonText: {
        color: theme.colors.accentForeground,
        fontSize: 12,
        fontWeight: "600" as const,
      },
      status: { fontSize: 12, color: theme.colors.foregroundMuted, marginTop: 4 },
    }),
    [theme, layout.compact],
  );

  const queryClient = useQueryClient();
  // The workspace directory is the repository the pool is anchored to.
  const directory = useWorkspace(workspaceId, (workspace) => workspace.directory);
  const cwd = directory ?? "";

  const inspectPool = useRpc(poolInspect);
  const claimSlot = useRpc(poolClaim);
  const releaseSlot = useRpc(poolRelease);

  const pool = useQuery({
    queryKey: ["warm-pool", cwd],
    queryFn: () => inspectPool({ cwd }),
    enabled: cwd.length > 0,
  });

  const claimMutation = useMutation({
    mutationFn: ({ slot }: { slot: string }) => claimSlot({ cwd, slot, task: "claimed from pool panel" }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["warm-pool", cwd] }),
  });

  const releaseMutation = useMutation({
    mutationFn: ({ slot }: { slot: string }) => releaseSlot({ cwd, slot }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["warm-pool", cwd] }),
  });

  const busy = claimMutation.isPending || releaseMutation.isPending;

  const lastMessage = useMemo(() => {
    const result = claimMutation.data ?? releaseMutation.data;
    if (!result) return null;
    return "message" in result ? result.message : null;
  }, [claimMutation.data, releaseMutation.data]);

  const onRefresh = useCallback(() => {
    queryClient.invalidateQueries({ queryKey: ["warm-pool", cwd] });
  }, [queryClient, cwd]);

  return (
    <ScrollView style={styles.screen} contentContainerStyle={{ gap: 4 }}>
      <Text style={styles.heading}>Warm worktree pool</Text>
      <Text style={styles.muted} numberOfLines={2}>
        {pool.data?.anchor ?? (cwd ? "resolving…" : "no git checkout")}
      </Text>

      {pool.isPending ? <ActivityIndicator /> : null}

      {pool.data?.slots.map((slot) => {
        const locked = slot.lockedForSeconds !== null;
        const statusColor = slot.dirty
          ? theme.colors.statusDanger
          : locked
            ? theme.colors.accent
            : theme.colors.foregroundMuted;
        const status = slot.dirty
          ? "dirty"
          : locked
            ? `locked ${formatAge(slot.lockedForSeconds)}`
            : slot.exists
              ? "free"
              : "absent";
        return (
          <View key={slot.name} style={styles.row}>
            <View style={{ flex: 1, gap: 2 }}>
              <Text style={styles.name}>{slot.name}</Text>
              <Text style={styles.detail} numberOfLines={1}>
                {slot.branch ?? "no branch"} · {formatBytes(slot.bytes)}
                {slot.exists && !slot.trackedByGit ? " · untracked by git" : ""}
              </Text>
            </View>
            <View style={[styles.pill, { backgroundColor: `${statusColor}22` }]}>
              <Text style={[styles.pillText, { color: statusColor }]}>{status}</Text>
            </View>
            {locked ? (
              <Pressable
                accessibilityRole="button"
                accessibilityLabel={`Release ${slot.name}`}
                disabled={busy}
                onPress={() => releaseMutation.mutate({ slot: slot.name })}
                style={styles.button}
              >
                <Text style={styles.buttonText}>Release</Text>
              </Pressable>
            ) : (
              <Pressable
                accessibilityRole="button"
                accessibilityLabel={`Claim ${slot.name}`}
                disabled={busy}
                onPress={() => claimMutation.mutate({ slot: slot.name })}
                style={styles.button}
              >
                <Text style={styles.buttonText}>Claim</Text>
              </Pressable>
            )}
          </View>
        );
      })}

      {pool.data && pool.data.slots.length === 0 ? (
        <Text style={styles.muted}>No slots yet. They are created on first claim.</Text>
      ) : null}

      {pool.isError ? <Text style={styles.status}>Could not read the pool.</Text> : null}
      {lastMessage ? <Text style={styles.status}>{lastMessage}</Text> : null}

      <Pressable accessibilityRole="button" onPress={onRefresh} style={styles.button}>
        <Text style={styles.buttonText}>Refresh</Text>
      </Pressable>
    </ScrollView>
  );
}

export default function contribute(client: PluginClientContext) {
  client.addWorkspacePanel({
    id: "warm-pool",
    title: "Warm Pool",
    icon: "Layers",
    context: "workspace",
    Component: PoolPanel,
  });

  return () => {};
}