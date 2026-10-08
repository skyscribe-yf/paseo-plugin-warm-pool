#!/usr/bin/env bash
# pool-take.sh — 原子认领一个池槽位（防多 agent 并发抢位）。
# 用法: pool-take.sh <slot> <任务标签>
#   slot 通常取 lane-a / lane-b / lane-c（implementer 默认并发 3，见 SKILL.md 的 Capacity）。
#   脚本本身不限制槽位数量；Paseo 插件侧默认开 8 个，两者是同一批槽位。
# 退出码: 0=认领成功（stdout 输出 worktree 路径）; 2=被健康认领占用;
#         3=槽位脏/创建失败（需人工查看）; 4=请求的槽位就是当前所在槽位（自我争抢）
# 陈旧认领（超过 POOL_STALE_SEC 默认 6h）自动窃取并在 stderr 说明。
# 窃取只按认领时长判断（记录 PID 仅作展示——编排器的每条 shell 都是短命进程，
# 进程存活检查在 agent 环境下会立即误判为可窃取，等于没有锁）。
# NOTE: 工作区本地工具（.gitignore scripts/* 挡住，不入库）；池槽位分支名按工作区命名空间隔离。
# 锚点由 git-common-dir 推导（见 wt-anchor.sh）：同一 repo 的任意入口共享同一个池与同一把锁，
# 不同 repo 完全隔离。若锚点随 cwd 变化，锁就退化成「本次会话内有效」，形同虚设。
set -euo pipefail

# 注意：本脚本 source wt-anchor.sh（依赖其函数），不要用子 shell
slot="${1:?usage: pool-take.sh <slot> <task-label>}"
task="${2:?usage: pool-take.sh <slot> <task-label>}"

_wt_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=wt-anchor.sh
. "$_wt_dir/wt-anchor.sh"

git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "not in a git repo" >&2; exit 1; }

# 旧锚点仍有池却没迁移时，必须 fail closed。
# 放行的代价不是「多一个空目录」：新位置没有依赖树，下一个槽位要全量重装
# （实测 16 槽位约 14.6 GB），而旧池变成无人认领的孤儿。与其静默烧掉十几 GB，
# 不如停下来让人显式跑一次 wt-migrate-anchor.sh。
if wt_has_legacy_pool; then
  legacy=$(wt_legacy_anchor_dir)
  echo "pool-take: 检测到未迁移的旧池 $legacy/pool，拒绝在新锚点建空池。" >&2
  echo "  原因: 新锚点无依赖树，直接认领会触发全量重装并留下孤儿池。" >&2
  echo "  解决: 先迁移（依赖树随目录 mv，不重新安装）——" >&2
  echo "        $_wt_dir/wt-migrate-anchor.sh [--dry-run]" >&2
  echo "  临时: WT_ANCHOR_DISABLE=1 继续用旧锚点（仍会有 Paseo 观察器超限问题）。" >&2
  exit 3
fi

wt_ensure_dirs
POOL="$(wt_pool_dir)"

# 当前若已身处某个池槽位，跳过它：否则在 lane-a 里跑 implementer 会把 lane-a
# 分配给自己，两个 lane 在同一目录并发写。嵌套 run 必须用另一个槽位。
CURRENT_SLOT=""
case "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" in
  "$POOL"/*) CURRENT_SLOT="${POOL}/$(basename "$(git rev-parse --show-toplevel)")" ;;
esac
if [ "$slot" = "$(basename "${CURRENT_SLOT:-/nonexistent}")" ] && [ -n "$CURRENT_SLOT" ]; then
  echo "pool-take: refusing to hand slot '$slot' to a run already inside it" >&2
  echo "  cwd   = $CURRENT_SLOT" >&2
  echo "  fix   = pick another slot (nested runs need their own)" >&2
  exit 4
fi
LOCK="$(wt_lock_file "$slot")"
STALE_SEC="${POOL_STALE_SEC:-21600}"
umask 022
mkdir -p "$(dirname "$LOCK")"
wt="$POOL/$slot"

# 槽位不存在时自动创建（复用优先：已存在则只做 reset+clean，依赖树原地保留）。
if [ ! -d "$wt" ]; then
  if ! mkdir "$LOCK" 2>/dev/null; then
    echo "busy: slot '$slot' is being created or claimed by another run" >&2
    exit 2
  fi
  created_slot=1
  echo "pool-take: slot '$slot' does not exist yet — creating it (first run only)" >&2
  if ! "$_wt_dir/wt-pool.sh" "pool/$slot" "${POOL_SLOT_BASE:-origin/master}" >/dev/null; then
    echo "pool-take: failed to create slot worktree for '$slot'" >&2
    rm -rf "$LOCK"          # 回滚锁：否则留下孤儿锁，下个 run 永远 busy
    exit 3
  fi
else
  # 复用路径：先抢锁。抢不到就是别人在用。
  if ! mkdir "$LOCK" 2>/dev/null; then
    claim_file="$LOCK/claim"
    age=$(( $(date +%s) - $(stat -c %Y "$claim_file" 2>/dev/null || echo "$(date +%s)") ))
    if [ "$age" -ge "$STALE_SEC" ]; then
      echo "pool-take: stealing $slot — stale claim ($(( age / 3600 ))h old): $(tr '\n' ' ' < "$claim_file" 2>/dev/null)" >&2
      rm -rf "$LOCK"
      mkdir "$LOCK"
    else
      echo "busy: $slot claimed $(( age / 60 ))m ago [$(tr '\n' ' ' < "$claim_file" 2>/dev/null)] — release with pool-release.sh or wait (steal threshold POOL_STALE_SEC=${STALE_SEC}s)" >&2
      exit 2
    fi
  fi
fi

printf '%s %s %s\n' "$$" "$(date -Iseconds)" "$task" > "$LOCK/claim"

branch=$(git -C "$wt" branch --show-current 2>/dev/null || true)
if [ "$branch" != "pool/$slot" ]; then
  echo "WARN: $wt is on '$branch' (expected pool/$slot) — previous run may have crashed mid-PR" >&2
fi
dirty=$(git -C "$wt" status --porcelain || true)
if [ -n "$dirty" ]; then
  echo "DIRTY: $wt has uncommitted leftovers — inspect before reuse" >&2
  echo "  triage: git -C $wt status && git -C $wt diff" >&2
  echo "  then  : pool-release.sh $slot to release, or stash/clean manually" >&2
  exit 3                  # 保留锁：脏槽位必须人工介入，不允许下个 run 静默覆盖
fi
printf '%s\n' "$wt"
