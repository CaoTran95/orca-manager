#!/usr/bin/env bash
# Guard: chỉ Orca Manager/main được sửa Harness. Read-only.
# Dùng: guard-harness.sh [--staged] [--quiet]
#   mặc định: working tree (kể cả untracked) + commit của branch chưa có trong main.
#   --staged: chỉ file đã stage (dùng trong hook).
# Ở feat/<key>, file ghi được (docs/tasks/, file thường, không symlink):
#   1. Naming: YYYY-MM-DD-<key>[-suffix].md  (key: "/" trong tên branch -> "-").
#   2. Ownership manifest: front matter `owns:` trong file chính YYYY-MM-DD-<key>.md
#      - file chưa có trong main: tự khai báo trong file chính của feature là đủ;
#      - file đã có trong main: chỉ hợp lệ nếu main duyệt trong config/task-ownership.yaml
#        (features: {<key>: [paths]}; chỉ sửa được ở main).
#      Không glob; không README/TEMPLATE/HANDOFF_TEMPLATE; tên phải có tiền tố ngày.
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

key=""; case "$branch" in feat/*) key=$(printf '%s' "${branch#feat/}" | tr '/' '-');; esac

owns_of(){ # stdin: nội dung file task -> mỗi dòng một path khai báo trong front matter
  ruby -ryaml -e 'c=STDIN.read; exit 0 unless c=~/\A---\n(.*?)\n---\n/m; d=(YAML.safe_load($1) rescue nil); o=d.is_a?(Hash)? d["owns"] : nil; puts o if o.is_a?(Array)' 2>/dev/null
}
valid_owned(){ [[ "$1" =~ ^docs/tasks/[0-9]{4}-[0-9]{2}-[0-9]{2}-[A-Za-z0-9._-]+\.md$ ]] && ! [[ "$1" =~ /(README|TEMPLATE|HANDOFF_TEMPLATE)\.md$ ]]; }

declared=""; approved=""
if [ -n "$key" ]; then
  for f in "$root"/docs/tasks/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-"$key".md; do
    if [ -f "$f" ] && [ ! -L "$f" ]; then declared+=$'\n'"$(owns_of <"$f")"; fi
  done
  approved=$(git -C "$root" show main:config/task-ownership.yaml 2>/dev/null | K="$key" ruby -ryaml -e 'd=(YAML.safe_load(STDIN.read) rescue nil); f=d.is_a?(Hash)? d["features"] : nil; o=f.is_a?(Hash)? f[ENV["K"]] : nil; puts o if o.is_a?(Array)' 2>/dev/null)
fi

changed=$(mktemp); trap 'rm -f "$changed"' EXIT
if [ "$staged" = 1 ]; then
  git -C "$root" diff --cached --name-only --no-renames -z | tr '\0' '\n' >"$changed"
else
  git -C "$root" status --porcelain=v1 -z -uall --no-renames | tr '\0' '\n' | sed -E 's/^.{3}//' >"$changed"
  if git -C "$root" rev-parse --verify -q refs/heads/main >/dev/null; then
    git -C "$root" log main..HEAD --no-merges --name-only --no-renames --format= >>"$changed"
  else
    echo "guard: WARN không có branch main local, bỏ qua kiểm tra commit" >&2
  fi
fi

in_main(){ git -C "$root" cat-file -e "main:$1" 2>/dev/null; }
listed(){ printf '%s\n' "$2" | grep -Fxq -- "$1"; }
allowed(){ # $1 = path
  local p=$1
  [ -n "$key" ] || return 1
  [ -L "$root/$p" ] && return 1
  [[ "$p" =~ ^docs/tasks/[0-9]{4}-[0-9]{2}-[0-9]{2}-${key}(-[A-Za-z0-9._-]+)?\.md$ ]] && return 0
  valid_owned "$p" || return 1
  listed "$p" "$approved" && return 0
  in_main "$p" && return 1
  listed "$p" "$declared"
}

# Nội dung trùng khít main (vd. merge/đồng bộ Harness do user duyệt) không phải sai lệch Harness.
same_as_main(){
  local p=$1 m w
  [ -L "$root/$p" ] && return 1
  m=$(git -C "$root" rev-parse -q --verify "main:$p" 2>/dev/null || echo none)
  if [ "$staged" = 1 ]; then w=$(git -C "$root" rev-parse -q --verify ":$p" 2>/dev/null || echo none)
  elif [ -f "$root/$p" ] && [ ! -L "$root/$p" ]; then w=$(git -C "$root" hash-object -- "$root/$p")
  else w=none; fi
  [ "$m" = "$w" ]
}

bad=""
while IFS= read -r p; do
  [ -z "$p" ] && continue
  same_as_main "$p" && continue
  [ "$staged" = 0 ] && case "$p" in .serena/*) continue;; esac
  allowed "$p" || bad+="  - $p"$'\n'
done < <(sort -u "$changed")

if [ -n "$bad" ]; then
  {
  echo "guard: VI PHẠM Harness Ownership — worktree '$root_real' (branch $branch) không được sửa:"
  printf '%s' "$bad"
  echo "Chỉ Orca Manager/main được sửa Harness. Ở feat/* chỉ ghi docs/tasks/<ngày>-${key:-<feature-key>}[-suffix].md hoặc file khai báo trong 'owns:' của file chính."
  echo "Cần làm: hoàn tác phần trái phép của bạn (không reset/checkout cưỡng bức khi chưa hỏi user), ghi Change Request vào task file và báo user."
  } >&2
  exit 1
fi
say "guard: OK ($branch)."
exit 0
