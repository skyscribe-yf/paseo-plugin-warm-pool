#!/usr/bin/env bash
# wt-migrate-anchor.sh — 把池搬到当前锚点布局（<repo-root>.wt-pool）。
#
# 一次性迁移脚本，搬运依赖树（node_modules/.venv）而不是重装。
#
# 支持两种源布局，按 wt_legacy_dirs 报告的顺序依次处理：
#   1. <toplevel>/.worktrees/pool            最早的「工作目录布局」
#   2. <git-common-dir>/wt-pool/pool         2026-10-08 之前的锚点布局
# 目标：<repo-root>.wt-pool/pool
#
# 为什么必须搬：把池留在 .git 里，Paseo 的 workspace-git-service 会把 git-common-dir
# 当观察根，linux.js 的 MAX_WATCHED_DIRECTORIES=5000 被池槽位顶穿，git 元数据降级轮询。
#
# 关键细节：mv 之后必须做两件事，只做一件不够（已实测）：
#   1. 改写 .git/worktrees/<name>/gitdir 里的绝对路径
#   2. git worktree prune 清掉 stale 记账
#   `git worktree repair` 单独执行**不会**修复被移动的 worktree（它修的是反向损坏），
#   所以必须手工改写 gitdir。漏了这步，池槽位会变成 prunable，git 层面等于不存在。
#
# ⚠ 迁移不要在有 agent 正跑在池槽位里时执行：槽位的绝对路径会变，
#   正在运行的 session 的 cwd 会指向已不存在的目录。用 pgrep/git 检查后再跑。
#
# 用法: wt-migrate-anchor.sh [--dry-run]
set -euo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

_wt_self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=wt-anchor.sh
. "$_wt_self/wt-anchor.sh"
unset _wt_self

git rev-parse --show-toplevel >/dev/null 2>&1 || {
  echo "wt-migrate-anchor: 不在 git 仓库里" >&2; exit 1; }

NEW_POOL="$(wt_pool_dir)"
COMMON="$(git rev-parse --path-format=absolute --git-common-dir)"

mapfile -t ALL_LEGACY < <(wt_legacy_dirs | sort -u)
# 只保留真有槽位的源：残留的空目录（如早已迁走的 .worktrees）不值得走一遍 mv/prune/rmdir
LEGACIES=()
for leg in "${ALL_LEGACY[@]}"; do
  [ -d "$leg/pool" ] || continue
  # 排除 .locks 之类的元数据目录：它不是工作树槽位，迁它只会留下一个假锚点
  [ -n "$(find "$leg/pool" -mindepth 1 -maxdepth 1 -type d -not -name '.*' -print -quit 2>/dev/null)" ] || continue
  LEGACIES+=("$leg")
done
if [ "${#LEGACIES[@]}" -eq 0 ]; then
  echo "无需迁移：没有发现带槽位的旧布局池（当前锚点 $NEW_POOL）。"
  exit 0
fi

echo "目标池: $NEW_POOL"
for leg in "${LEGACIES[@]}"; do
  echo "候选源: $leg/pool ($(find "$leg/pool" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l) 个槽位)"
done

# 有 agent 正在槽位里跑时中止：mv 会让它们的 cwd 失效。
if [ "$DRY" -eq 0 ]; then
  for leg in "${LEGACIES[@]}"; do
    for d in "$leg/pool"/*/; do
      [ -d "$d" ] || continue
      wt_gitdir="$d/.git"
      [ -f "$wt_gitdir" ] || continue
      if [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]; then
        echo "中止：槽位 $(basename "$d") 有未提交改动，迁移会挪走别人的在制品。" >&2
        echo "  $d" >&2
        exit 1
      fi
    done
  done
fi

if [ "$DRY" = 1 ]; then
  echo "[dry-run] 未做任何改动。"
  exit 0
fi

mkdir -p "$(dirname "$NEW_POOL")"
fail=0

for leg in "${LEGACIES[@]}"; do
  LEGACY="$leg/pool"
  [ -d "$LEGACY" ] || continue
  echo
  echo "迁移 $LEGACY -> $NEW_POOL"

  # 拒绝覆盖：目标已存在同名槽位时中止，避免混合两个布局的记账。
  for d in "$LEGACY"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    if [ -e "$NEW_POOL/$name" ]; then
      echo "中止：$NEW_POOL/$name 已存在。请先人工确认两边的槽位归属。" >&2
      exit 1
    fi
  done

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

  # 旧目录清空后移除（保留锚点本身，避免误删用户其它内容）
  rmdir "$LEGACY" 2>/dev/null && echo "已移除空目录 $LEGACY" || true
  rmdir "$leg" 2>/dev/null && echo "已移除空目录 $leg" || true
done

# 校验：每个槽位都必须能被 git 正常识别且不 prunable
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

[ "$fail" = 0 ] || exit 1
echo
echo "迁移完成。依赖树随目录保留，无需重新安装。"
echo "旧锚点不再被使用；确认无误后可手工删除残留目录。"