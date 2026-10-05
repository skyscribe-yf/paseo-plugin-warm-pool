#!/usr/bin/env bash
# pool-release.sh — 释放池槽位认领（lane 结束/PR 推送并切回池分支后调用）。
# 用法: pool-release.sh <slot>
#   slot 通常取 lane-a / lane-b / lane-c（implementer 默认并发 3）。
# 锁路径与 pool-take.sh 完全一致（都由 wt-anchor.sh 解析），否则释放会落空。
set -euo pipefail
slot="${1:?usage: pool-release.sh <slot>}"

_wt_self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=wt-anchor.sh
. "$_wt_self/wt-anchor.sh"
unset _wt_self

git rev-parse --show-toplevel >/dev/null 2>&1 || exit 1
LOCK="$(wt_lock_file "$slot")"
rm -rf "$LOCK"
echo "released: $slot -> $LOCK"