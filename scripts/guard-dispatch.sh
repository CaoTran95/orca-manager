#!/usr/bin/env bash
# Read-only preflight trước khi giao việc cho worker (Codex/Cursor): Worker Isolation.
# Dùng: guard-dispatch.sh <worktree-path> [--kind business|harness]
#   Từ chối nếu path là:
#     - checkout chính của Orca Manager (main) hoặc của bất kỳ repo nghiệp vụ đã đăng ký trong Orca;
#     - không phải linked worktree, hoặc detached HEAD;
#     - worktree Orca Manager khi kind=business (worker không code trong Orca Manager);
#     - kind=harness mà branch không phải harness/* đã được main duyệt (harness_staging).
#   Branch hợp lệ cho business: feat/* (hoặc branch khác của linked worktree repo nghiệp vụ).
# Test: ORCA_GUARD_PRIMARY_PATHS="p1:p2" thay cho `orca repo list`.
# Exit 0 = được giao; 1 = bị từ chối; 2 = lỗi sử dụng.
set -uo pipefail
path=""; kind=business
while [ $# -gt 0 ]; do case "$1" in --kind) shift; kind=${1:-};; -*) echo "usage: $0 <worktree-path> [--kind business|harness]" >&2; exit 2;; *) path=$1;; esac; shift; done
[ -n "$path" ] && [ -d "$path" ] || { echo "dispatch: thiếu hoặc sai worktree path" >&2; exit 2; }
case "$kind" in business|harness) ;; *) echo "dispatch: --kind phải là business|harness" >&2; exit 2;; esac
deny(){ echo "dispatch: TỪ CHỐI — $1" >&2; exit 1; }

real=$(cd "$path" && pwd -P)
top=$(git -C "$real" rev-parse --show-toplevel 2>/dev/null) || deny "$real không phải git worktree"
top=$(cd "$top" && pwd -P)
[ "$top" = "$real" ] || deny "$real không phải gốc worktree (gốc: $top)"
gd=$(cd "$real" && cd "$(git rev-parse --git-dir)" && pwd -P)
cd_=$(cd "$real" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
[ "$gd" != "$cd_" ] || deny "$real là checkout chính (không phải linked worktree); worker chỉ làm việc trong worktree riêng"

if [ -n "${ORCA_GUARD_PRIMARY_PATHS:-}" ]; then primaries=$(printf '%s' "$ORCA_GUARD_PRIMARY_PATHS" | tr ':' '\n')
else primaries=$(orca repo list --json 2>/dev/null | ruby -rjson -e 'JSON.parse(STDIN.read)["result"]["repos"].each{|r| puts r["path"]}' 2>/dev/null); fi
while IFS= read -r p; do
  [ -n "$p" ] && [ -d "$p" ] && [ "$(cd "$p" && pwd -P)" = "$real" ] && deny "$real là checkout chính của một repo đã đăng ký"
done <<<"$primaries"

branch=$(git -C "$real" symbolic-ref --short -q HEAD) || deny "detached HEAD"
main_root=$(dirname "$cd_")
is_manager=0; [ -f "$main_root/config/repositories.yaml" ] && [ -f "$main_root/scripts/guard-harness.sh" ] && is_manager=1

if [ "$is_manager" = 1 ]; then
  [ "$kind" = harness ] || deny "worktree Orca Manager ($branch) không nhận task nghiệp vụ; Leader tự cập nhật task record"
  [[ "$branch" == harness/* ]] || deny "task Harness chỉ giao ở branch harness/<topic> đã duyệt, không phải '$branch'"
  ruby "$main_root/scripts/ownership.rb" staging-branches 2>/dev/null | grep -Fxq -- "$branch" || deny "branch $branch chưa được main duyệt trong harness_staging (config/task-ownership.yaml)"
else
  [ "$kind" = business ] || deny "kind=harness chỉ áp dụng cho worktree Orca Manager"
fi
dirty=$(git -C "$real" status --porcelain | grep -v '^?? \.serena/' | wc -l | tr -d ' ')
echo "dispatch: OK path=$real branch=$branch kind=$kind local_changes=$dirty (một worktree chỉ một worker ghi)"
exit 0
