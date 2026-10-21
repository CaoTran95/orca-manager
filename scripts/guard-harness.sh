#!/usr/bin/env bash
# Guard: chỉ Orca Manager/main được sửa Harness. Read-only.
# Dùng: guard-harness.sh [--staged] [--quiet]
#   mặc định: kiểm tra working tree + commit của branch so với main.
#   --staged: chỉ kiểm tra file đã stage (dùng trong git hook).
# Ở feat/*: chỉ cho phép docs/tasks/YYYY-MM-DD-<feature-key>[-suffix].md của chính feature.
# Exit 0 = hợp lệ; 1 = vi phạm; 2 = không xác định được ngữ cảnh.
set -uo pipefail
staged=0; quiet=0
for a in "$@"; do case "$a" in --staged) staged=1;; --quiet) quiet=1;; *) echo "usage: $0 [--staged] [--quiet]" >&2; exit 2;; esac; done
say(){ [ "$quiet" = 1 ] || echo "$@"; }

root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "guard: không phải git repo" >&2; exit 2; }
common=$(cd "$root" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
main_root=$(dirname "$common")
root_real=$(cd "$root" && pwd -P)
branch=$(git -C "$root" symbolic-ref --short -q HEAD || echo "(detached)")

# Chỉ áp dụng cho repo Orca Manager (có config/repositories.yaml của Harness).
[ -f "$main_root/config/repositories.yaml" ] || { echo "guard: không phải Orca Manager" >&2; exit 2; }

if [ "$root_real" = "$main_root" ] && [ "$branch" = "main" ]; then
  say "guard: Harness owner (main) — cho phép."; exit 0
fi

key=""
case "$branch" in feat/*) key=${branch#feat/};; esac
if [ -z "$key" ]; then
  # Không phải main và không phải feat/*: không có quyền ghi gì ngoài đọc.
  allowed_re='^$'
else
  esc=$(printf '%s' "$key" | sed 's/[][\.*^$+?(){}|/]/\\&/g')
  allowed_re="^docs/tasks/[0-9]{4}-[0-9]{2}-[0-9]{2}-${esc}(-[^/]+)?\.md$"
fi

changed=$(mktemp); trap 'rm -f "$changed"' EXIT
if [ "$staged" = 1 ]; then
  git -C "$root" diff --cached --name-only --no-renames >"$changed"
else
  git -C "$root" status --porcelain --no-renames -uall | sed -E 's/^.{3}//' >"$changed"
  if git -C "$root" rev-parse --verify -q main >/dev/null && base=$(git -C "$root" merge-base main HEAD 2>/dev/null); then
    git -C "$root" diff --name-only --no-renames "$base" HEAD >>"$changed"
  fi
fi
# Chỉ cho phép untracked local state không thuộc Harness.
bad=$(sort -u "$changed" | grep -v '^$' | grep -vE '^\.serena/' | grep -vE "$allowed_re" || true)

if [ -n "$bad" ]; then
  echo "guard: VI PHẠM Harness Ownership — worktree '$root_real' (branch $branch) không được sửa:" >&2
  echo "$bad" | sed 's/^/  - /' >&2
  echo "Chỉ Orca Manager/main được sửa Harness. Ở feat/* chỉ được ghi docs/tasks/<ngày>-${key:-<feature-key>}[-suffix].md." >&2
  echo "Việc cần làm: hoàn tác phần trái phép của bạn (không dùng reset/checkout cưỡng bức khi chưa hỏi user), ghi Change Request vào task file và báo user." >&2
  exit 1
fi
say "guard: OK ($branch)."
exit 0
