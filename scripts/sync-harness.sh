#!/usr/bin/env bash
# Đồng bộ Harness từ main sang MỘT feature worktree bằng REBASE (không merge).
#   sync-harness.sh --check [--worktree PATH]       read-only; mặc định mọi worktree
#   sync-harness.sh --apply --worktree PATH [--confirm BRANCH]
# --apply: chạy tại main (Harness owner); chỉ khi user yêu cầu. Cần xác nhận: gõ đúng tên branch trên
#   TTY, hoặc --confirm BRANCH (Leader chỉ truyền sau khi user đã duyệt trong phiên).
# An toàn: không stash/reset/force-push; không tự giải conflict. Từ chối khi: có thay đổi local
#   (trừ .serena/), đang rebase/merge/cherry-pick, có merge commit trong branch (rebase sẽ làm phẳng),
#   branch đã push (cần force-push), hoặc mô phỏng replay từng commit báo conflict.
#   Trước khi rebase tạo ref sao lưu refs/orca-sync-backup/<branch>/<giờ>. Nếu rebase vẫn conflict,
#   `git rebase --abort` (khôi phục đúng trạng thái trước; điều kiện clean đảm bảo không mất gì).
# Exit 0 = ok/đồng bộ xong; 1 = không an toàn hoặc thất bại; 2 = lỗi sử dụng.
set -uo pipefail
mode=""; target=""; confirm=""
while [ $# -gt 0 ]; do case "$1" in
  --check) mode=check;; --apply) mode=apply;;
  --worktree) shift; target=${1:-};; --confirm) shift; confirm=${1:-};;
  *) echo "usage: $0 --check [--worktree PATH] | --apply --worktree PATH [--confirm BRANCH]" >&2; exit 2;; esac; shift; done
[ -n "$mode" ] || { echo "cần --check hoặc --apply" >&2; exit 2; }

common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P) || exit 2
main_root=$(dirname "$common")
git -C "$main_root" rev-parse --verify -q refs/heads/main >/dev/null || { echo "sync: thiếu branch main" >&2; exit 2; }

# evaluate <worktree>: in lý do không an toàn ra stdout (mỗi dòng một lý do); đặt BEHIND, AHEAD, BRANCH.
evaluate(){
  local w=$1 gd c t acc n
  BRANCH=$(git -C "$w" symbolic-ref --short -q HEAD || echo "")
  reasons=""
  [ -n "$BRANCH" ] || { echo "detached HEAD"; return; }
  [ "$BRANCH" != main ] || { echo "là branch main (Harness owner)"; return; }
  gd=$(cd "$w" && cd "$(git rev-parse --git-dir)" && pwd -P)
  for f in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do [ -e "$gd/$f" ] && echo "đang dở dang: $f"; done
  n=$(git -C "$w" status --porcelain | grep -v '^?? \.serena/' | wc -l | tr -d ' ')
  [ "$n" = 0 ] || echo "có $n thay đổi local/untracked (không tự stash)"
  BEHIND=$(git -C "$w" rev-list --count HEAD..main); AHEAD=$(git -C "$w" rev-list --count main..HEAD)
  [ -z "$(git -C "$w" rev-list --merges main..HEAD)" ] || echo "branch có merge commit (rebase sẽ làm phẳng) — xử lý thủ công"
  if up=$(git -C "$w" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
    [ "$(git -C "$w" rev-list --count "$up"..HEAD)" = "$AHEAD" ] || echo "commit đã push lên $up — rebase cần force-push (không làm)"
  fi
  [ "$BEHIND" = 0 ] && return
  # mô phỏng replay từng commit lên main bằng merge-tree (không chạm worktree/index)
  acc=$(git -C "$w" rev-parse main)
  while IFS= read -r c; do
    t=$(git -C "$w" merge-tree --write-tree --merge-base="$c^" "$acc" "$c" 2>/dev/null) || { echo "conflict khi replay $(git -C "$w" log -1 --format='%h %s' "$c")"; return; }
    acc=$(git -C "$w" commit-tree "$t" -p "$acc" -m sim </dev/null)
  done < <(git -C "$w" rev-list --reverse --no-merges main..HEAD)
}

EV=$(mktemp); LOG=$(mktemp); trap 'rm -f "$EV" "$LOG"' EXIT
run_eval(){ evaluate "$1" >"$EV"; out=$(cat "$EV"); }

list_worktrees(){ git -C "$main_root" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}'; }

if [ "$mode" = check ]; then
  rc=0
  if [ -n "$target" ]; then ws=$target; else ws=$(list_worktrees | grep -vxF "$main_root"); fi
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    run_eval "$w"; b=${BRANCH:-?}
    if [ -n "$out" ]; then rc=1; echo "UNSAFE  $(basename "$w") [$b] behind=${BEHIND:-?} ahead=${AHEAD:-?}"; echo "$out" | sed 's/^/          - /'
    elif [ "${BEHIND:-0}" = 0 ]; then echo "CURRENT $(basename "$w") [$b] đã chứa main (ahead=$AHEAD)"
    else echo "SAFE    $(basename "$w") [$b] behind=$BEHIND ahead=$AHEAD — rebase mô phỏng không conflict"; fi
  done <<<"$ws"
  exit $rc
fi

# --- apply ---
[ -n "$target" ] && [ -d "$target" ] || { echo "sync: --apply cần --worktree PATH hợp lệ" >&2; exit 2; }
w=$(cd "$target" && pwd -P)
[ "$(cd "$(git rev-parse --show-toplevel)" && pwd -P)" = "$main_root" ] && [ "$(git symbolic-ref --short -q HEAD)" = main ] || { echo "sync: --apply chỉ chạy tại Orca Manager/main (Harness owner)" >&2; exit 1; }
[ "$w" != "$main_root" ] || { echo "sync: không rebase chính main" >&2; exit 1; }
list_worktrees | grep -qxF "$w" || { echo "sync: $w không phải worktree của repo này" >&2; exit 1; }
run_eval "$w"; b=$BRANCH
if [ -n "$out" ]; then echo "sync: KHÔNG AN TOÀN — $w [$b]:" >&2; echo "$out" | sed 's/^/  - /' >&2; exit 1; fi
[ "$BEHIND" != 0 ] || { echo "sync: $b đã chứa main, không cần làm gì."; exit 0; }
echo "Sẽ rebase $b ($w) lên main: replay $AHEAD commit, behind=$BEHIND."
git -C "$w" log --oneline main..HEAD | sed 's/^/  /'
echo "Lưu ý: dừng agent đang ghi trong worktree này trước (một worktree một writer)."
if [ -z "$confirm" ]; then
  [ -r /dev/tty ] || { echo "sync: không có TTY; cần --confirm $b" >&2; exit 1; }
  printf 'Gõ chính xác tên branch (%s) để xác nhận rebase: ' "$b" >/dev/tty; read -r confirm </dev/tty
fi
[ "$confirm" = "$b" ] || { echo "sync: xác nhận không khớp, hủy." >&2; exit 1; }

backup="refs/orca-sync-backup/$b/$(date +%Y%m%dT%H%M%S)"
git -C "$w" update-ref "$backup" HEAD
if ! git -C "$w" -c rebase.autoStash=false rebase main >"$LOG" 2>&1; then
  files=$(git -C "$w" diff --name-only --diff-filter=U | tr '\n' ' ')
  git -C "$w" rebase --abort
  echo "sync: rebase conflict ($files) — đã abort, worktree về nguyên trạng. Sao lưu: $backup. Cần xử lý thủ công." >&2
  tail -5 "$LOG" >&2; exit 1
fi
echo "sync: rebase xong. HEAD=$(git -C "$w" rev-parse --short HEAD). Sao lưu: $backup"
fail=0
[[ "$b" == harness/* ]] || for f in CLAUDE.md AGENTS.md .cursor/rules/orca-manager.mdc; do cmp -s "$w/$f" "$main_root/$f" || { echo "sync: CẢNH BÁO $f vẫn khác main"; fail=1; }; done
( cd "$w" && "$main_root/scripts/guard-harness.sh" --quiet ) || { echo "sync: guard báo vi phạm sau rebase"; fail=1; }
echo "Khôi phục (nếu cần, do user quyết): git -C \"$w\" reset --hard $backup"
exit $fail
