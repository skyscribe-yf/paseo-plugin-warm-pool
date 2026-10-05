#!/usr/bin/env bash
# wt-anchor.sh — 池/锁的唯一锚点解析（被 wt-pool.sh / pool-take.sh / pool-release.sh source）。
#
# WHY 锚点必须挂在 git-common-dir 上，而不是工作目录：
#   平台（Claude Code / Paseo / pi）在 worktree 模式下会把 agent 的 cwd 放进一个
#   一次性的托管目录（Paseo: ~/.paseo/worktrees/<hash>/<slug>，每次新建、路径被占用就
#   加后缀重建）。任何以 `$PWD` / `git rev-parse --show-toplevel` 为根的 pool 或 lock，
#   生命周期都等于「本次会话」——跨 run 复用必然失效，lock 也永远看不到别的会话。
#
#   `git rev-parse --path-format=absolute --git-common-dir` 指向仓库唯一的共享 .git
#   目录，它满足全部要求：
#     · 同一 repo 的主 checkout 与任意 worktree —— 同一个锚点，复用生效
#     · 同一 repo 从不同文件夹进入 —— 同一个锚点，不会因入口不同而失联
#     · 不同 repo（哪怕同一 remote 的不同 clone）—— 不同 .git，锚点不同，完全隔离
#   且 .git 本就在版本控制与同步范围之外，不会被提交、不会被 rsync 污染，
#   删除仓库时锚点随之清理。
#
# 用法: source wt-anchor.sh 后调用
#   wt_anchor_dir   → <git-common-dir>/wt-pool
#   wt_pool_dir     → <git_anchor_dir>/pool
#   wt_lock_dir     → <wt_anchor_dir>/locks
#   wt_lock_file <slot>
#   wt_ensure_dirs
# 环境变量:
#   WT_ANCHOR_DISABLE=1   回退到旧的 <toplevel>/.worktrees 布局（迁移期逃生阀）
set -euo pipefail

wt_anchor_dir() {
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || common=""
  if [ -z "$common" ]; then
    # 老 git（<2.31）没有 --path-format=absolute，退回手工绝对化
    common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
  fi
  if [ "${WT_ANCHOR_DISABLE:-0}" = 1 ]; then
    # 逃生阀：恢复迁移前的布局
    printf '%s\n' "$(git rev-parse --show-toplevel)/.worktrees"
    return 0
  fi
  printf '%s\n' "$common/wt-pool"
}

wt_pool_dir() { printf '%s/pool\n' "$(wt_anchor_dir)"; }
wt_lock_dir() { printf '%s/locks\n' "$(wt_anchor_dir)"; }
wt_lock_file() { printf '%s/%s.lock\n' "$(wt_lock_dir)" "${1:?slot required}"; }

wt_ensure_dirs() {
  mkdir -p "$(wt_anchor_dir)" "$(wt_pool_dir)" "$(wt_lock_dir)"
}

# wt_legacy_dirs — 迁移前用过的布局（可能非空），供迁移脚本判断是否需要搬运。
wt_legacy_dirs() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  [ -n "$root" ] && printf '%s\n' "$root/.worktrees"
}