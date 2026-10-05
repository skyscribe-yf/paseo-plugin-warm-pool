#!/usr/bin/env bash
# wt-pool.sh — reuse-first git worktree helper for agents and humans.
#
# WHY: a fresh worktree costs ~33 MB of host writes (git checkout) plus a full
# dependency bootstrap (~104 MB for web/node_modules). Reusing the same worktree
# and only moving the branch tip keeps node_modules/.venv in place, which turns
# the dependency step into a hardlink refresh (~4 MB). See
# .agents/skills/using-git-worktrees/SKILL.md.
#
# Usage:
#   scripts/wt-pool.sh <branch> [base]     # print the worktree path on stdout
#   scripts/wt-pool.sh --print <branch>    # path only (no reset, no bootstrap)
#   scripts/wt-pool.sh --self-test         # exercise reuse/create in a temp repo
#
# Behaviour: reuse an existing worktree for <branch> (reset + clean, keeps
# ignored dependency dirs), else create one under the git-common-dir anchor
# <repo>/.git/wt-pool/pool/<branch> — see wt-anchor.sh for why the anchor is the
# git identity and not the working directory.
# Status goes to stderr, so `wt=$(scripts/wt-pool.sh foo)` is safe.
# NOTE: 本文件被 .gitignore 的 scripts/* 规则挡住（工作区本地工具，不入库）。
# 每个需要池的工作区各自持有副本；正本纪律见 implementer skill 的 Worktree pool 小节。
set -euo pipefail

# 池与锁的锚点解析（唯一真源，勿在其它脚本里另写一份）
_wt_self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=wt-anchor.sh
. "$_wt_self/wt-anchor.sh"
unset _wt_self

say() { printf '%s\n' "$*" >&2; }
die() { say "wt-pool: $*"; exit 1; }

bootstrap() { # idempotent dependency bootstrap — never a full reinstall
  local wt="$1"
  [ "${WT_POOL_BOOTSTRAP:-1}" = 1 ] || return 0
  if [ -f "$wt/web/package.json" ]; then
    if [ -x "$wt/web/node_modules/.bin/tsc" ] || [ -d "$wt/web/node_modules/.pnpm" ]; then
      say "wt-pool: web deps present, skipping install ($wt/web/node_modules)"
    else
      command -v pnpm >/dev/null 2>&1 || die "pnpm not on PATH; cannot bootstrap $wt/web"
      say "wt-pool: bootstrapping web deps (first time for this worktree)"
      (cd "$wt/web" && pnpm install --frozen-lockfile --prefer-offline) \
        || say "wt-pool: WARNING pnpm install failed; run it manually in $wt/web"
    fi
  fi
  if [ -f "$wt/pyproject.toml" ] && [ -f "$wt/uv.lock" ]; then
    if [ -x "$wt/.venv/bin/python" ]; then
      say "wt-pool: python venv present, skipping sync ($wt/.venv)"
    else
      command -v uv >/dev/null 2>&1 || { say "wt-pool: uv not on PATH; skipping python env"; return 0; }
      say "wt-pool: bootstrapping python env (first time for this worktree)"
      (cd "$wt" && uv sync --frozen) \
        || say "wt-pool: WARNING uv sync failed; run it manually in $wt"
    fi
  fi
}

find_worktree_for_branch() { # $1=repo root, $2=branch -> path or empty
  git -C "$1" worktree list --porcelain | awk -v want="refs/heads/$2" '
    $1 == "worktree" { path = $2 }
    $1 == "branch" && $2 == want { print path; exit }'
}

main() {
  local want_path_only=0
  case "${1:-}" in
    --self-test) self_test; exit 0 ;;
    --print)     want_path_only=1; shift ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
  esac
  local branch="${1:-}" base="${2:-origin/master}"
  [ -n "$branch" ] || die "usage: wt-pool.sh <branch> [base]"

  local root git_dir git_common
  root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
  git_dir=$(cd "$(git rev-parse --git-dir)" && pwd -P)
  git_common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
  wt_ensure_dirs
  local pool; pool=$(wt_pool_dir)

  # 注意：这里**不再**因为「已处于 linked worktree」就短路返回 cwd。
  # 平台（Paseo 等）的 worktree 目录是一次性的，若沿用旧短路，pool 逻辑一行都不会执行，
  # 跨 run 复用必然失效。worktree 内调用本脚本是合法且常见的。
  #
  # 但必须拒绝**真正的套娃**：目标是当前所在槽位本身或其子目录。
  # 注意不能一刀切拒绝「从槽位里建另一个槽位」——嵌套 run（本槽位内的
  # implementer 再开 lane）需要这个能力，且目标是同级目录，不是子目录。
  local slot="${branch#pool/}"
  [ -n "$slot" ] || slot="$branch"
  case "$slot" in */*) slot="${slot//\//__}" ;; esac   # 其余斜杠压平，避免意外的嵌套目录
  local target="$pool/$slot"

  # 只有当当前目录本身就是某个槽位时才拒绝。主 checkout 天然**包含** .git/（也就是
  # 包含整个池），那种「target 在 root 之内」是正常的，不能误伤。
  case "$root" in
    "$pool"/*)
      if [ "$root" = "$target" ] || [ "${target#"$root"/}" != "$target" ]; then
        say "wt-pool: refusing to create slot '$slot' inside itself ($root)"
        [ "$want_path_only" = 1 ] && exit 0
        die "refusing to nest a pool slot inside itself ($root)"
      fi
      ;;
  esac

  # 从 common-dir 操作，这样主 checkout 与任意 worktree 看到同一份池状态。
  local op="$git_common"
  local wt=""
  wt=$(find_worktree_for_branch "$op" "$branch")
  # 只认池内的 worktree。旧布局（<toplevel>/.worktrees/pool/…）迁移后仍在 git 记账里，
  # 会让这里返回一个池外路径；跟着它走就会 reset 一个已废弃的目录，并输出一个
  # 尚不存在的路径给调用方。
  case "$wt" in
    "$pool"/*) ;;
    *) wt="" ;;
  esac
  [ -n "$wt" ] || wt="$target"

  if [ "$want_path_only" = 1 ]; then
    [ -n "$wt" ] && [ -d "$wt" ] && printf '%s\n' "$wt"
    return 0
  fi

  if [ -d "$wt" ] && [ -n "$(find_worktree_for_branch "$op" "$branch")" ]; then
    say "wt-pool: reusing $wt (reset --hard + clean -fd)"
    git -C "$op" worktree prune >/dev/null
    local ref="$base"
    git -C "$op" rev-parse --verify --quiet "$base" >/dev/null || ref="HEAD"
    git -C "$wt" reset -q --hard "$ref"
    git -C "$wt" clean -qfd
  else
    say "wt-pool: creating $wt"
    mkdir -p "$(dirname "$wt")"
    git -C "$op" worktree prune >/dev/null
    # 先看分支是否已存在：槽位目录可能已被删除而分支残留（例如迁移或手工清理后）。
    # 此时应复用该分支，而不是用 -b 创建——那会因分支已存在而失败。
    if git -C "$op" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$op" worktree add -q "$wt" "$branch"
    elif git -C "$op" rev-parse --verify --quiet "$base" >/dev/null; then
      git -C "$op" worktree add -q "$wt" -b "$branch" "$base"
    else
      git -C "$op" worktree add -q "$wt" -b "$branch" HEAD
    fi
  fi

  bootstrap "$wt"
  printf '%s\n' "$wt"
}

self_test() {
  local script abs
  script="${1:-$0}"
  case "$script" in
    /*) abs="$script" ;;
    *)  abs="$(cd "$(dirname "$script")" && pwd)/$(basename "$script")" ;;
  esac
  local tmp; tmp=$(mktemp -d /tmp/wt-pool-selftest.XXXXXX)
  trap 'rm -rf "$tmp"' RETURN
  (
    set -e
    cd "$tmp"
    git init -q -b master .
    git config user.email t@t; git config user.name t
    mkdir -p web; printf '{"name":"x"}' > web/package.json
    printf 'node_modules\n.venv\n.worktrees\n' > .gitignore
    printf 'x\n' > tracked.txt
    git add -A; git commit -qm init

    export WT_POOL_BOOTSTRAP=0   # the fake project must not trigger a real install

    local wt1 wt2
    wt1=$("$abs" feat/demo master)
    [ -d "$wt1" ] || { echo "FAIL: create did not produce a directory"; exit 1; }
    [ -f "$wt1/tracked.txt" ] || { echo "FAIL: tracked file missing in new worktree"; exit 1; }
    [ "$(git -C "$wt1" branch --show-current)" = "feat/demo" ] || { echo "FAIL: wrong branch"; exit 1; }

    mkdir -p "$wt1/web/node_modules"; printf 'dep\n' > "$wt1/web/node_modules/marker.txt"
    printf 'scratch\n' > "$wt1/untracked.txt"
    wt2=$("$abs" feat/demo master)
    [ "$wt1" = "$wt2" ] || { echo "FAIL: reuse returned a different path"; exit 1; }
    [ -f "$wt1/web/node_modules/marker.txt" ] || { echo "FAIL: reuse wiped node_modules"; exit 1; }
    [ -e "$wt1/untracked.txt" ] && { echo "FAIL: reuse left untracked files"; exit 1; }
    echo "PASS: reuse works (same path, ignored deps kept, untracked cleaned)"
    echo "PASS: created=$(basename "$wt1")  branch=$(git -C "$wt1" branch --show-current)"

    # --- 锚点契约：池挂在 git-common-dir 下，不随 cwd 变化 ---
    case "$wt1" in
      "$(git rev-parse --path-format=absolute --git-common-dir)"/wt-pool/*)
        echo "PASS: pool is anchored under git-common-dir" ;;
      *) echo "FAIL: pool not under git-common-dir: $wt1"; exit 1 ;;
    esac

    # 换一个文件夹（模拟平台的临时 worktree）进入，同一分支必须命中同一个槽位。
    # 这是本次修复的核心回归：旧实现会在第一屏短路返回临时目录，复用彻底失效。
    local elsewhere="$tmp/.elsewhere"
    mkdir -p "$elsewhere"
    ( cd "$elsewhere" && git init -q -b master . && git config user.email t@t && git config user.name t )
    # 把「平台 worktree」挂到同一个 repo 上
    git worktree add -q "$elsewhere/agent-wt" -b agent/wt master
    local wt3
    wt3=$(cd "$elsewhere/agent-wt" && "$abs" feat/demo master)
    [ "$wt3" = "$wt1" ] || {
      echo "FAIL: call from a linked worktree did not reuse the pool slot"; echo "  got=$wt3 want=$wt1"; exit 1; }
    echo "PASS: same repo + different cwd -> same pool slot (reuse survives platform worktrees)"

    # 不同 repo 必须完全隔离
    local other="$tmp/other-repo"
    mkdir -p "$other"
    ( cd "$other" && git init -q -b master . && git config user.email t@t && git config user.name t
      printf 'y\n' > other.txt && git add -A && git commit -qm init
      export WT_POOL_BOOTSTRAP=0
      own=$("$abs" feat/demo master)
      case "$own" in
        "$tmp"/.git/*) echo "FAIL: different repo resolved to the same anchor"; exit 1 ;;
        *) echo "PASS: different repo -> isolated anchor ($(dirname "$(dirname "$own")") relative to its own .git)" ;;
      esac
    )
  )
}

main "$@"
