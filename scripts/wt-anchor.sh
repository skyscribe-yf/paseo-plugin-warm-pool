#!/usr/bin/env bash
# wt-anchor.sh — 池/锁的唯一锚点解析（被 wt-pool.sh / pool-take.sh / pool-release.sh source）。
#
# WHY 锚点必须由 git-common-dir 推导，而不是工作目录：
#   平台（Claude Code / Paseo / pi）在 worktree 模式下会把 agent 的 cwd 放进一个
#   一次性的托管目录（Paseo: ~/.paseo/worktrees/<hash>/<slug>，每次新建、路径被占用就
#   加后缀重建）。任何以 `$PWD` / `git rev-parse --show-toplevel` 为根的 pool 或 lock，
#   生命周期都等于「本次会话」——跨 run 复用必然失效，lock 也永远看不到别的会话。
#
#   `git rev-parse --path-format=absolute --git-common-dir` 指向仓库唯一的共享 .git
#   目录，由它推导出的锚点满足：
#     · 同一 repo 的主 checkout 与任意 worktree —— 同一个锚点，复用生效
#     · 同一 repo 从不同文件夹进入 —— 同一个锚点，不会因入口不同而失联
#     · 不同 clone（哪怕同一 remote）—— 路径不同，锚点不同，完全隔离
#
# WHY 锚点不能放在 .git 里面（2026-10-08 修正）：
#   旧布局是 `<git-common-dir>/wt-pool`。Paseo 的 workspace-git-service 会把
#   git-common-dir 当作观察根交给 file-observer，而 linux.js 的
#   MAX_WATCHED_DIRECTORIES = 5000。池槽位是完整 checkout（含 node_modules/.venv），
#   实测单个仓库的池可达 2 万~8 万目录，直接把观察器顶穿，于是
#   「Recursive file observation exceeded 5000 directories under <repo>/.git」
#   每 5 分钟复发一次，git 元数据降级为轮询。
#   新布局把锚点挪到仓库的**同级兄弟目录** `<repo-root>.wt-pool`：
#     · 出了观察根，目录数不再计入上限
#     · 仍然在版本控制与 rsync 范围之外，不会被提交或污染
#     · 仍然能由路径反推 repo（去掉 `.wt-pool` 后缀），warm-pool 插件的
#       parseSlotPath 依赖这一点
#     · 代价：删仓库不再自动带走锚点，需要手工清理（见 README）
#
# 用法: source wt-anchor.sh 后调用
#   wt_repo_root      → <repo-root>（git-common-dir 去掉尾部 /.git）
#   wt_anchor_dir     → <repo-root>.wt-pool
#   wt_pool_dir       → <wt_anchor_dir>/pool
#   wt_lock_dir       → <wt_anchor_dir>/locks
#   wt_lock_file <slot>
#   wt_ensure_dirs
#   wt_legacy_anchor_dir  → 旧锚点（迁移用；不存在则空）
#   wt_has_legacy_pool    → 0/1，旧池存在且非空（调用方据此 fail closed）
# 环境变量:
#   WT_ANCHOR_ROOT=<dir>   显式指定锚点目录（自行保证每个 repo 一个）
#   WT_ANCHOR_DISABLE=1    回退到旧的 <git-common-dir>/wt-pool 布局（迁移期逃生阀）
set -euo pipefail

# 仓库根：git-common-dir 去掉尾部 /.git。裸仓库（无 .git 后缀）不适用，调用方需处理。
wt_repo_root() {
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
  if [ -z "$common" ]; then
    # 老 git（<2.31）没有 --path-format=absolute，退回手工绝对化
    common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
  fi
  case "$common" in
    */.git) printf '%s\n' "${common%/.git}" ;;
    *) printf '%s\n' "$common" ;;
  esac
}

wt_anchor_dir() {
  if [ -n "${WT_ANCHOR_ROOT:-}" ]; then
    printf '%s\n' "$WT_ANCHOR_ROOT"
    return 0
  fi
  if [ "${WT_ANCHOR_DISABLE:-0}" = 1 ]; then
    # 逃生阀：恢复 2026-10-08 之前的布局
    git rev-parse --path-format=absolute --git-common-dir 2>/dev/null \
      || git rev-parse --git-common-dir
    return 0
  fi
  printf '%s.wt-pool\n' "$(wt_repo_root)"
}

wt_pool_dir() { printf '%s/pool\n' "$(wt_anchor_dir)"; }
wt_lock_dir() { printf '%s/locks\n' "$(wt_anchor_dir)"; }
wt_lock_file() { printf '%s/%s.lock\n' "$(wt_lock_dir)" "${1:?slot required}"; }

wt_ensure_dirs() {
  mkdir -p "$(wt_anchor_dir)" "$(wt_pool_dir)" "$(wt_lock_dir)"
}

# wt_legacy_anchor_dir — 2026-10-08 之前的锚点 <git-common-dir>/wt-pool，不存在则空。
wt_legacy_anchor_dir() {
  local common
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  [ -n "$common" ] || return 0
  printf '%s/wt-pool\n' "$common"
}

# wt_has_legacy_pool — 旧池存在且非空时返回 0。
#
# 存在的意义：新默认锚点与旧锚点并存时，若不拦住，一次 pool-take 会在新位置建空池，
# 触发全量依赖重装（实测 16 槽位约 14.6 GB），旧池则变成无人认领的孤儿。
# 与其静默烧掉十几 GB，不如让调用方 fail closed 并提示先跑 wt-migrate-anchor.sh。
wt_has_legacy_pool() {
  local legacy
  legacy=$(wt_legacy_anchor_dir) || return 1
  [ -n "$legacy" ] || return 1
  [ "$(wt_anchor_dir)" != "$legacy" ] || return 1
  [ -d "$legacy/pool" ] || return 1
  # 排除 .locks 之类的元数据目录：只有真正的槽位（工作树）才算「池非空」
  [ -n "$(find "$legacy/pool" -mindepth 1 -maxdepth 1 -type d -not -name '.*' -print -quit 2>/dev/null)" ]
}

# wt_legacy_dirs — 迁移脚本用的全部历史布局（可能非空），逐行输出。
#   <toplevel>/.worktrees          最早的「工作目录布局」
#   <git-common-dir>/wt-pool      2026-10-08 之前的锚点布局
wt_legacy_dirs() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || true
  [ -n "$root" ] && [ -d "$root/.worktrees" ] && printf '%s\n' "$root/.worktrees"
  local legacy
  legacy=$(wt_legacy_anchor_dir 2>/dev/null) || true
  if [ -n "$legacy" ] && [ -d "$legacy" ]; then
    [ "$legacy" = "$(wt_anchor_dir)" ] || printf '%s\n' "$legacy"
  fi
  return 0
}