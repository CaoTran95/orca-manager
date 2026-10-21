#!/usr/bin/env bash
# Tích hợp có kiểm soát thay đổi Harness do worker soạn ở worktree staging vào main (fast-forward).
#   integrate-harness.sh <harness/topic> [--confirm BRANCH]
# Chạy tại Orca Manager/main bởi Leader/user sau khi ĐÃ review diff. Điều kiện:
#   - branch nằm trong harness_staging của config/task-ownership.yaml (bản đã commit ở main);
#   - main sạch phần tracked; worktree staging sạch (không thay đổi local);
#   - main là tổ tiên của branch (nếu main đã tiến: rebase staging bằng sync-harness.sh --apply trước);
#   - check-config.sh và test-guard.sh PASS ngay trong worktree staging (trước khi chạm main).
# Xác nhận: gõ đúng tên branch trên TTY, hoặc --confirm (chỉ truyền sau khi user duyệt trong phiên).
# Chỉ `git merge --ff-only`; không reset/stash/force. Exit 0 = đã tích hợp; 1 = từ chối/thất bại.
set -uo pipefail
br=""; confirm=""
while [ $# -gt 0 ]; do case "$1" in --confirm) shift; confirm=${1:-};; -*) echo "usage: $0 <harness/topic> [--confirm BRANCH]" >&2; exit 2;; *) br=$1;; esac; shift; done
[ -n "$br" ] || { echo "usage: $0 <harness/topic> [--confirm BRANCH]" >&2; exit 2; }
die(){ echo "integrate: $1" >&2; exit 1; }

common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P) || exit 2
main_root=$(dirname "$common")
top=$(cd "$(git rev-parse --show-toplevel)" && pwd -P)
[ "$top" = "$main_root" ] && [ "$(git symbolic-ref --short -q HEAD)" = main ] || die "chỉ chạy tại Orca Manager/main"
[[ "$br" == harness/* ]] || die "branch phải dạng harness/<topic>"
git rev-parse --verify -q "refs/heads/$br" >/dev/null || die "không có branch $br"
ruby "$main_root/scripts/ownership.rb" staging-branches | grep -Fxq -- "$br" || die "$br chưa được duyệt trong harness_staging (bản đã commit ở main)"
git diff --quiet && git diff --cached --quiet || die "main có thay đổi tracked chưa commit; xử lý trước"
git merge-base --is-ancestor main "$br" || die "main đã tiến trước $br; rebase staging bằng sync-harness.sh --apply --worktree <path> rồi chạy lại"
[ "$(git rev-list --count main.."$br")" != 0 ] || die "$br không có commit mới so với main"

w=$(git worktree list --porcelain | awk -v b="refs/heads/$br" '/^worktree /{p=substr($0,10)} $1=="branch" && $2==b {print p}')
[ -n "$w" ] || die "$br không được checkout ở worktree nào; tạo worktree staging riêng để kiểm thử"
[ -z "$(git -C "$w" status --porcelain | grep -v '^?? \.serena/')" ] || die "worktree staging $w còn thay đổi local"

echo "== Commit sẽ tích hợp ($br -> main, fast-forward)"; git log --oneline main.."$br"
echo "== Diff stat"; git diff --stat main.."$br"
echo "== Validation trong worktree staging ($w)"
( cd "$w" && scripts/check-config.sh ) || die "check-config.sh thất bại ở staging; không tích hợp"
tl=$(mktemp); trap 'rm -f "$tl"' EXIT
( cd "$w" && scripts/test-guard.sh >"$tl" 2>&1 ) || { grep "FAIL" "$tl" | head -5 >&2; die "test-guard.sh thất bại ở staging; không tích hợp"; }
echo "validation: check-config + test-guard PASS"

if [ -z "$confirm" ]; then
  [ -r /dev/tty ] || die "không có TTY; cần --confirm $br sau khi user duyệt"
  printf 'Gõ chính xác tên branch (%s) để xác nhận tích hợp vào main: ' "$br" >/dev/tty; read -r confirm </dev/tty
fi
[ "$confirm" = "$br" ] || die "xác nhận không khớp, hủy"
git merge --ff-only "$br" || die "fast-forward thất bại; main không đổi"
echo "integrate: main -> $(git rev-parse --short HEAD). Chưa push. Rà soát bằng scripts/check-config.sh."
