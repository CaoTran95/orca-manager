#!/usr/bin/env bash
# Cài guard hooks vào hooks dir DÙNG CHUNG của repo (<git-common-dir>/hooks).
# Stub tự tìm Orca Manager main lúc chạy => không cố định path, an toàn khi di chuyển repo/worktree.
# Chạy tại main. Không ghi đè hook không thuộc guard; gỡ core.hooksPath chỉ khi nó trỏ tới .githooks cũ của guard.
set -euo pipefail
cd "$(dirname "$0")/.."
common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
hooks="$common/hooks"; mkdir -p "$hooks"
hp=$(git config --local --get core.hooksPath || true)
case "$hp" in ""|*/.githooks) ;; *) echo "core.hooksPath=$hp không phải của guard; dừng (không ghi đè)." >&2; exit 1;; esac
stub='#!/usr/bin/env bash
# orca-manager-guard (cài bởi scripts/install-hooks.sh)
common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P) || exit 1
g="$(dirname "$common")/scripts/guard-harness.sh"
[ -x "$g" ] || { echo "guard: thiếu $g — chặn commit (fail closed). Báo user." >&2; exit 1; }
exec "$g" --staged'
stub_msg='#!/usr/bin/env bash
# orca-manager-guard (cài bởi scripts/install-hooks.sh)
common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P) || exit 1
g="$(dirname "$common")/scripts/guard-harness.sh"
[ -x "$g" ] || { echo "guard: thiếu $g — chặn commit (fail closed). Báo user." >&2; exit 1; }
exec "$g" --commit-msg "$1"'
for h in pre-commit pre-merge-commit commit-msg; do
  f="$hooks/$h"
  if [ -e "$f" ] && ! grep -q 'orca-manager-guard' "$f"; then echo "$f đã tồn tại và không phải guard; dừng." >&2; exit 1; fi
  if [ "$h" = commit-msg ]; then printf '%s\n' "$stub_msg" >"$f"; else printf '%s\n' "$stub" >"$f"; fi
  chmod +x "$f"
done
[ -n "$hp" ] && git config --local --unset core.hooksPath
echo "Đã cài guard hooks vào $hooks (core.hooksPath đã gỡ nếu từng đặt)."
