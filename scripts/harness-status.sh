#!/usr/bin/env bash
# Read-only: mỗi worktree của Orca Manager đang dùng Harness nào so với main?
# Không sửa/stash/sync worktree nào. Chạy tại bất kỳ worktree nào.
#   same     = file trong worktree trùng nội dung main (agent khởi động tại worktree đó sẽ đọc bản này)
#   OLD/DIFF = khác main => agent ở worktree đó KHÔNG nạp quy tắc mới (Claude/Codex đọc CLAUDE.md/AGENTS.md theo cwd)
#   absent   = chưa có file đó trong worktree
# Lưu ý: so sánh nội dung chứng minh file nào nằm trong worktree, KHÔNG chứng minh agent đã đọc nó.
set -uo pipefail
common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
main_root=$(dirname "$common")
harness=(CLAUDE.md AGENTS.md .cursor/rules/orca-manager.mdc config/repositories.yaml config/task-ownership.yaml scripts/guard-harness.sh docs/LEADER_PLAYBOOK.md docs/tasks/HANDOFF_TEMPLATE.md)
printf '%-52s %-34s %-8s %s\n' WORKTREE BRANCH HOOKS GUARD
git -C "$main_root" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}' | while IFS= read -r w; do
  b=$(git -C "$w" symbolic-ref --short -q HEAD || echo detached)
  hd=$(git -C "$w" rev-parse --path-format=absolute --git-path hooks 2>/dev/null)
  if [ -x "$hd/pre-commit" ] && grep -q orca-manager-guard "$hd/pre-commit" 2>/dev/null; then h=active; else h=MISSING; fi
  if [ "$w" = "$main_root" ]; then g=owner
  elif ( cd "$w" && "$main_root/scripts/guard-harness.sh" --quiet >/dev/null 2>&1 ); then g=ok; else g=VIOLATION; fi
  dirty=$(git -C "$w" status --porcelain | grep -vc '^?? \.serena/')
  printf '%-52s %-34s %-8s %s (local changes: %s)\n' "$(basename "$w")" "$b" "$h" "$g" "$dirty"
  if [ "$w" != "$main_root" ]; then
    line=""
    for f in "${harness[@]}"; do
      if [ ! -f "$w/$f" ]; then s=absent; elif cmp -s "$w/$f" "$main_root/$f"; then s=same; else s=DIFF; fi
      line+="$f=$s  "
    done
    echo "    $line"
  fi
done
