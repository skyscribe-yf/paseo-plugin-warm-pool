#!/usr/bin/env bash
# wt-migrate-anchor.sh — 把池从「工作目录布局」搬到「git-common-dir 锚点布局」。
#
# 一次性迁移脚本。旧布局 <toplevel>/.worktrees/pool，新布局 <git-common-dir>/wt-pool/pool。
# 依赖树（node_modules/.venv）随目录整体 mv，不重新安装。
#
# 关键细节：mv 之后必须做两件事，只做一件不够（已实测）：
#   1. 改写 .git/worktrees/<name>/gitdir 里的绝对路径
#   2. git worktree prune 清掉 stale 记账
#   `git worktree repair` 单独执行**不会**修复被移动的 worktree（它修的是反向损坏），
#   所以必须手工改写 gitdir。漏了这步，池槽位会变成 prunable，git 层面等于不存在。
#
# 用法: wt-migrate-anchor.sh [--dry-run]
set -euo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

_wt_self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=wt-anchor.sh
. "$_wt_self/wt-anchor.sh"
unset _wt_self

TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "wt-migrate-anchor: 不在 git 仓库里" >&2; exit 1; }

LEGACY="$TOPLEVEL/.worktrees/pool"
NEW_POOL="$(wt_pool_dir)"
COMMON="$(git rev-parse --path-format=absolute --git-common-dir)"

if [ ! -d "$LEGACY" ]; then
  echo "无需迁移：$LEGACY 不存在（已在新布局，或从没有池）。"
  exit 0
fi
if [ "$(cd "$LEGACY" && pwd -P)" = "$(mkdir -p "$NEW_POOL" && cd "$NEW_POOL" && pwd -P)" ]; then
  echo "无需迁移：旧新路径相同。"
  exit 0
fi

echo "旧池: $LEGACY"
echo "新池: $NEW_POOL"
echo "槽位: $(find "$LEGACY" -mindepth 1 -maxdepth 1 -type d | wc -l)"

if [ "$DRY" = 1 ]; then
  echo "[dry-run] 未做任何改动。"
  exit 0
fi

# 拒绝覆盖：目标已存在同名槽位时中止，避免混合两个布局的记账。
for d in "$LEGACY"/*/; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  if [ -e "$NEW_POOL/$name" ]; then
    echo "中止：$NEW_POOL/$name 已存在。请先人工确认两边的槽位归属。" >&2
    exit 1
  fi
done

mkdir -p "$(dirname "$NEW_POOL")"
# 逐槽位 mv，保证能逐个改写 gitdir 记账
for d in "$LEGACY"/*/; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  echo "迁移槽位 $name ..."
  mv "$d" "$NEW_POOL/$name"
  # git 记账目录名通常等于 worktree 目录名，但用 git 反查更稳
  gitdir_file="$COMMON/worktrees/$name/gitdir"
  if [ -f "$gitdir_file" ]; then
    printf '%s\n' "$NEW_POOL/$name/.git" > "$gitdir_file"
    echo "  已改写 $(basename "$COMMON/worktrees/$name")/gitdir"
  else
    echo "  警告：未找到 $gitdir_file，该槽位可能不是本 repo 的 worktree，跳过记账修正" >&2
  fi
done

git -C "$COMMON" worktree prune

# 校验：每个槽位都必须能被 git 正常识别且不 prunable
fail=0
echo
echo "校验："
git -C "$COMMON" worktree list
for d in "$NEW_POOL"/*/; do
  [ -d "$d" ] || continue
  if git -C "$d" rev-parse --git-dir >/dev/null 2>&1; then
    echo "  OK  $(basename "$d")  branch=$(git -C "$d" branch --show-current 2>/dev/null)"
  else
    echo "  失败 $(basename "$d")：git 无法识别，需人工介入" >&2
    fail=1
  fi
done

# 旧目录清空后移除（保留 .worktrees 本身，避免误删用户其它内容）
rmdir "$LEGACY" 2>/dev/null && echo "已移除空目录 $LEGACY" || true

[ "$fail" = 0 ] || exit 1
echo
echo "迁移完成。依赖树随目录保留，无需重新安装。"