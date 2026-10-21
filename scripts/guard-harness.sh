#!/usr/bin/env bash
# Guard: chỉ Orca Manager/main được sửa Harness. Read-only.
# Dùng: guard-harness.sh [--staged] [--quiet]
#   mặc định: working tree (kể cả untracked) + thay đổi ròng của branch so với điểm tách khỏi main
#             (bao gồm cả nội dung đến từ commit merge).
#   --staged: chỉ file đã stage (dùng trong hook; áp dụng cả cho merge commit đang tạo).
# Ở feat/<key>, file ghi được (docs/tasks/, file thường, không symlink):
#   1. Naming: YYYY-MM-DD-<key>[-suffix].md, với điều kiện <key> là key DÀI NHẤT khớp tên
#      trong số các feature đã biết (tránh feature `a` lấy file chính của feature `a-b`).
#   2. File mới của feature lớn: front matter `owns:` trong file chính YYYY-MM-DD-<key>.md,
#      miễn không bị feature/registry khác claim (scripts/ownership.rb conflicts).
#   3. File được main duyệt trong config/task-ownership.yaml (owner hoặc grandfathered).
# Mọi path có nội dung trùng MỘT phiên bản đã từng có trên main (đồng bộ/merge từ main) không bị
# tính là sai lệch Harness.
# Exit 0 = hợp lệ; 1 = vi phạm; 2 = không xác định được ngữ cảnh (hook coi là chặn).
set -uo pipefail
staged=0; quiet=0
for a in "$@"; do case "$a" in --staged) staged=1;; --quiet) quiet=1;; *) echo "usage: $0 [--staged] [--quiet]" >&2; exit 2;; esac; done
say(){ [ "$quiet" = 1 ] || echo "$@"; }

root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "guard: không phải git repo" >&2; exit 2; }
common=$(cd "$root" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
main_root=$(dirname "$common")
root_real=$(cd "$root" && pwd -P)
branch=$(git -C "$root" symbolic-ref --short -q HEAD || echo "(detached)")
[ -f "$main_root/config/repositories.yaml" ] || { echo "guard: không xác định được Orca Manager main ($main_root)" >&2; exit 2; }

if [ "$root_real" = "$main_root" ] && [ "$branch" = "main" ]; then
  say "guard: Harness owner (main) — cho phép."; exit 0
fi

own="$main_root/scripts/ownership.rb"
key=""; case "$branch" in feat/*) key=$(printf '%s' "${branch#feat/}" | tr '/' '-');; esac

approved=""; conflict_paths=""
if [ -n "$key" ]; then
  approved=$(cd "$root" && ruby "$own" registry-paths "$key" 2>/dev/null)
  conflict_paths=$(cd "$root" && ruby "$own" conflicts --for "$key" --paths-only 2>/dev/null)
fi
owns_of(){ # stdin: nội dung file task -> mỗi dòng một path khai báo trong front matter
  ruby -ryaml -e 'c=STDIN.read; exit 0 unless c=~/\A---\n(.*?)\n---\n/m; d=(YAML.safe_load($1) rescue nil); o=d.is_a?(Hash)? d["owns"] : nil; puts o if o.is_a?(Array)' 2>/dev/null
}
valid_owned(){ [[ "$1" =~ ^docs/tasks/[0-9]{4}-[0-9]{2}-[0-9]{2}-[A-Za-z0-9._-]+\.md$ ]] && ! [[ "$1" =~ /(README|TEMPLATE|HANDOFF_TEMPLATE)\.md$ ]]; }
declared=""
if [ -n "$key" ]; then
  for f in "$root"/docs/tasks/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-"$key".md; do
    if [ -f "$f" ] && [ ! -L "$f" ]; then declared+=$'\n'"$(owns_of <"$f")"; fi
  done
fi

changed=$(mktemp); trap 'rm -f "$changed"' EXIT
if [ "$staged" = 1 ]; then
  git -C "$root" diff --cached --name-only --no-renames -z | tr '\0' '\n' >"$changed"
else
  git -C "$root" status --porcelain=v1 -z -uall --no-renames | tr '\0' '\n' | sed -E 's/^.{3}//' >"$changed"
  if git -C "$root" rev-parse --verify -q refs/heads/main >/dev/null; then
    base=$(git -C "$root" merge-base main HEAD 2>/dev/null) && git -C "$root" diff --name-only --no-renames "$base" HEAD >>"$changed"
  else
    echo "guard: WARN không có branch main local, bỏ qua kiểm tra commit" >&2
  fi
fi

in_main(){ git -C "$root" cat-file -e "main:$1" 2>/dev/null; }
listed(){ printf '%s\n' "$2" | grep -Fxq -- "$1"; }

# Nội dung (blob) của path trùng một phiên bản từng có trên main => lấy từ main, không phải sai lệch.
from_main(){
  local p=$1 w c
  [ -L "$root/$p" ] && return 1
  if [ "$staged" = 1 ]; then w=$(git -C "$root" rev-parse -q --verify ":$p" 2>/dev/null || echo none)
  elif [ -f "$root/$p" ]; then w=$(git -C "$root" hash-object -- "$root/$p")
  else w=none; fi
  if [ "$w" = none ]; then in_main "$p" && return 1 || return 0; fi
  [ "$(git -C "$root" rev-parse -q --verify "main:$p" 2>/dev/null)" = "$w" ] && return 0
  while IFS= read -r c; do
    [ "$(git -C "$root" rev-parse -q --verify "$c:$p" 2>/dev/null)" = "$w" ] && return 0
  done < <(git -C "$root" log main --format=%H -- "$p" 2>/dev/null)
  return 1
}

allowed(){ # $1 = path
  local p=$1 nm
  [ -n "$key" ] || return 1
  [ -L "$root/$p" ] && return 1
  if [[ "$p" =~ ^docs/tasks/[0-9]{4}-[0-9]{2}-[0-9]{2}-${key}(-[A-Za-z0-9._-]+)?\.md$ ]]; then
    nm=$(cd "$root" && ruby "$own" naming-owner "$p" 2>/dev/null)
    { [ -z "$nm" ] || [ "$nm" = "$key" ]; } && return 0
  fi
  valid_owned "$p" || return 1
  listed "$p" "$approved" && return 0
  listed "$p" "$conflict_paths" && return 1
  in_main "$p" && return 1
  listed "$p" "$declared"
}

bad=""
while IFS= read -r p; do
  [ -z "$p" ] && continue
  if [ "$staged" = 0 ]; then case "$p" in .serena/*) continue;; esac; fi
  from_main "$p" && continue
  allowed "$p" || bad+="  - $p"$'\n'
done < <(sort -u "$changed")
# Khai báo owns: của chính worktree này mà xung đột với feature/registry khác là vi phạm, kể cả khi chưa sửa file đó.
while IFS= read -r p; do
  [ -n "$p" ] && listed "$p" "$conflict_paths" && ! listed "$p" "$approved" && bad+="  - $p (owns: xung đột với claim khác)"$'\n'
done < <(printf '%s\n' "$declared" | sort -u)

if [ -n "$bad" ]; then
  {
  echo "guard: VI PHẠM Harness Ownership — worktree '$root_real' (branch $branch) không được sửa:"
  printf '%s' "$bad"
  echo "Chỉ Orca Manager/main được sửa Harness. Ở feat/* chỉ ghi docs/tasks/<ngày>-${key:-<feature-key>}[-suffix].md, file khai báo 'owns:' không xung đột, hoặc file main đã duyệt."
  [ -n "$conflict_paths" ] && echo "Xung đột ownership: $(echo $conflict_paths) (chạy scripts/ownership.rb conflicts)."
  echo "Cần làm: hoàn tác phần trái phép của bạn (không reset/checkout cưỡng bức khi chưa hỏi user), ghi Change Request vào task file và báo user."
  } >&2
  exit 1
fi
say "guard: OK ($branch)."
exit 0
