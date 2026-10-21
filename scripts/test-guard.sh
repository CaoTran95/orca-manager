#!/usr/bin/env bash
# Kiểm thử guard-harness.sh + hooks trên clone/worktree TẠM. Không chạm repo thật hay feature worktree.
# Dùng: scripts/test-guard.sh   (exit 1 nếu có FAIL)
set -uo pipefail
SRC=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/guard-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ if [ "$2" = 1 ]; then pass=$((pass+1)); echo "[PASS] $1"; else fail=$((fail+1)); echo "[FAIL] $1"; fi; }

mkdir "$T/r"; git clone -q -b main "$SRC" "$T/r/main" || exit 2
cd "$T/r/main" || exit 2
git config user.email t@t; git config user.name t
git remote remove origin
cp "$SRC"/scripts/*.sh "$SRC"/scripts/*.rb scripts/; cp "$SRC"/config/*.yaml config/
printf "version: 2\ntasks: {}\n" > config/task-ownership.yaml
git add -A; git commit -qm base --allow-empty; scripts/install-hooks.sh >/dev/null
echo y > docs/tasks/2026-10-22-existing.md; git add -A; git commit -qm existing
git worktree add -q ../feat-big -b feat/big; cd ../feat-big; git config user.email t@t
G="$T/r/main/scripts/guard-harness.sh"
t(){ "$G" >/dev/null 2>&1; local rc=$?; [ "$rc" = "$2" ] && ok "$1 (rc=$rc)" 1 || ok "$1 (rc=$rc, expect $2)" 0; }
cm(){ git commit -qm "$1" >/dev/null 2>&1; echo $?; }

printf -- '---\nowns:\n  - docs/tasks/2026-10-22-sub-alpha.md\n  - docs/tasks/2026-10-22-existing.md\n  - docs/tasks/README.md\n  - docs/tasks/*.md\n  - docs/tasks/2026-10-22-glob-*.md\n---\n' > docs/tasks/2026-10-22-big.md
echo x > docs/tasks/2026-10-22-big-t1.md; echo x > docs/tasks/2026-10-22-sub-alpha.md
t "ALLOW primary + suffix + declared-new sub-task file" 0
echo x > docs/tasks/2026-10-22-undeclared.md; t "DENY undeclared sibling task file" 1; rm docs/tasks/2026-10-22-undeclared.md
echo z >> docs/tasks/2026-10-22-existing.md; t "DENY self-declared file that already exists in main" 1; git checkout -q -- docs/tasks/2026-10-22-existing.md
echo x >> docs/tasks/README.md; t "DENY declared README" 1; git checkout -q -- docs/tasks/README.md
echo x > docs/tasks/2026-10-22-glob-a.md; t "DENY glob declaration" 1; rm docs/tasks/2026-10-22-glob-a.md
echo x > docs/tasks/2026-10-22-other-feature.md; t "DENY another feature's task file" 1; rm docs/tasks/2026-10-22-other-feature.md
echo h >> CLAUDE.md; t "DENY CLAUDE.md edit" 1; git checkout -q -- CLAUDE.md
echo h >> scripts/guard-harness.sh; t "DENY scripts/ edit" 1; git checkout -q -- scripts/guard-harness.sh
echo x > config/new.yaml; t "DENY new file in config/" 1; rm config/new.yaml
ln -s ../../CLAUDE.md docs/tasks/2026-10-22-big-link.md; t "DENY symlink with allowed name" 1; rm docs/tasks/2026-10-22-big-link.md
mkdir -p "docs/tasks/sp ace"; echo x > "docs/tasks/sp ace/a.md"; t "DENY nested path with space" 1; rm -r "docs/tasks/sp ace"
rm CLAUDE.md; t "DENY deleting a Harness file" 1; git checkout -q -- CLAUDE.md
git add -A; [ "$(cm allowed)" = 0 ] && ok "hook ALLOWS commit of allowed task files" 1 || ok "hook allows commit of allowed files" 0
echo h >> CLAUDE.md; git add CLAUDE.md; [ "$(cm bad)" != 0 ] && ok "hook BLOCKS Harness commit" 1 || ok "hook blocks Harness commit" 0
git reset -q CLAUDE.md; git checkout -q -- CLAUDE.md
mkdir -p .serena; echo x > .serena/m; git add -f .serena/m; [ "$(cm s)" != 0 ] && ok "hook BLOCKS staged .serena" 1 || ok "hook blocks staged .serena" 0
git reset -q .serena/m; rm -rf .serena
t "ALLOW clean tree after allowed commit" 0

# Duyệt quyền bổ sung ở main (file đã có trong main)
(cd "$T/r/main"; printf 'version: 2\ntasks:\n  docs/tasks/2026-10-22-existing.md:\n    owner: big\n    owner_status: confirmed\n' > config/task-ownership.yaml; git add -A; git commit -qm approve)
echo z >> docs/tasks/2026-10-22-existing.md; t "ALLOW existing file approved in main config/task-ownership.yaml" 0; git checkout -q -- docs/tasks/2026-10-22-existing.md

# Commit trái phép khi hook bị vô hiệu (chỉ trong clone tạm) vẫn bị guard phát hiện
git config core.hooksPath /nonexistent; echo h >> AGENTS.md; git add AGENTS.md; git commit -qm sneaky >/dev/null 2>&1; git config --unset core.hooksPath
t "DENY committed violation when hook was bypassed" 1
git reset -q --hard HEAD~1

# Merge/đồng bộ main (nội dung trùng main) không bị chặn; merge kèm sửa Harness khác main thì bị chặn
(cd "$T/r/main"; echo m >> AGENTS.md; git commit -qam harness-update)
git merge -q --no-edit main >/dev/null 2>&1; [ $? = 0 ] && ok "pre-merge-commit ALLOWS merging main" 1 || ok "pre-merge-commit allows merging main" 0
t "ALLOW tree after merging main (main's changes not flagged)" 0
git reset -q --hard HEAD~1; git merge -q --no-edit --no-commit main >/dev/null 2>&1; echo h >> AGENTS.md; git add AGENTS.md
[ "$(cm merge-extra)" != 0 ] && ok "pre-merge-commit BLOCKS merge with extra Harness edit" 1 || ok "pre-merge-commit blocks extra edit" 0
git merge --abort 2>/dev/null; git reset -q --hard HEAD

git checkout -q -b feat/grp/sub main; echo x > docs/tasks/2026-10-22-grp-sub.md
t "ALLOW branch feat/grp/sub maps to key grp-sub" 0; rm docs/tasks/2026-10-22-grp-sub.md; git checkout -q feat/big
git checkout -q --detach; echo x > docs/tasks/2026-10-22-big-x.md; t "DENY any write on detached HEAD" 1; rm docs/tasks/2026-10-22-big-x.md; git checkout -q feat/big

# --- Xung đột ownership giữa nhiều feature ---
cd "$T/r/main"; git worktree add -q ../feat-other -b feat/other; cd ../feat-other; git config user.email t@t
printf -- '---\nowns:\n  - docs/tasks/2026-10-22-sub-alpha.md\n---\n' > docs/tasks/2026-10-22-other.md
t "DENY owns: sub-alpha also owned by feat/big (committed claim) — other side" 1
"$T/r/main/scripts/ownership.rb" conflicts >/dev/null 2>&1; [ $? = 1 ] && ok "ownership.rb conflicts reports ERROR (exit 1)" 1 || ok "ownership.rb conflicts exit 1" 0
cd ../feat-big; t "DENY feat/big too once both claim the same file (symmetric)" 1
cd ../feat-other; rm docs/tasks/2026-10-22-other.md
printf -- '---\nowns:\n  - docs/tasks/2026-10-22-existing.md\n---\n' > docs/tasks/2026-10-22-other.md
t "DENY owns: a file whose registry owner is another feature" 1
rm docs/tasks/2026-10-22-other.md
cd "$T/r/main"; git worktree add -q ../feat-big-api -b feat/big-api; cd ../feat-big-api; git config user.email t@t
echo x > docs/tasks/2026-10-22-big-api.md; t "ALLOW primary of longest key big-api" 0
cd ../feat-big; echo x > docs/tasks/2026-10-22-big-api.md; t "DENY feat/big taking primary of feat/big-api by suffix naming" 1; rm docs/tasks/2026-10-22-big-api.md
cd ../feat-other; git checkout -q -- . 2>/dev/null; cd ../feat-big
"$T/r/main/scripts/ownership.rb" validate >/dev/null 2>&1; [ $? = 0 ] && ok "ownership.rb validate accepts registry" 1 || ok "validate" 0

# --- Merge commit mang Harness khác main, tạo khi hook bị vô hiệu (chỉ clone tạm) ---
git checkout -q -b feat/mergecase main; echo a > docs/tasks/2026-10-22-mergecase.md; git add -A; git commit -qm mc
git config core.hooksPath /nonexistent
git checkout -q -b side main; echo side > docs/tasks/2026-10-22-mergecase-side.md; git add -A; git commit -qm side; git checkout -q feat/mergecase
git merge -q --no-commit --no-ff side >/dev/null 2>&1; [ -f .git ] || true; git rev-parse -q --verify MERGE_HEAD >/dev/null && ok "(setup) merge in progress" 1 || ok "(setup) merge in progress" 0; echo evil >> AGENTS.md; git add -A; git commit -qm "evil merge" >/dev/null 2>&1
git config --unset core.hooksPath
t "DENY merge commit carrying Harness content not from main (committed, hook bypassed)" 1
git reset -q --hard HEAD~1
# main tiến lên sau khi đồng bộ: nội dung cũ của main vẫn hợp lệ; main xóa file thì xóa ở feature cũng hợp lệ
git merge -q --no-edit main >/dev/null 2>&1
(cd "$T/r/main"; echo more >> AGENTS.md; git rm -q config/new.yaml 2>/dev/null; git commit -qam "main moves on" >/dev/null 2>&1)
t "ALLOW tree synced from older main after main advanced" 0
git checkout -q feat/big

# Di chuyển repo: stub trong common-dir/hooks không phụ thuộc path; core.hooksPath tuyệt đối thì mất hiệu lực
cd "$T"; mv r r2
(cd r2/main && git worktree repair ../feat-big >/dev/null 2>&1)
cd r2/feat-big; echo h >> CLAUDE.md; git add CLAUDE.md
[ "$(cm moved)" != 0 ] && ok "common-dir stub still BLOCKS after repo move + worktree repair" 1 || ok "stub after move" 0
git reset -q CLAUDE.md; git checkout -q -- CLAUDE.md
mkdir -p "$T/gone"; git config core.hooksPath "$T/gone/.githooks"; echo h >> CLAUDE.md; git add CLAUDE.md
[ "$(cm stale)" = 0 ] && ok "CONFIRMED: dangling absolute core.hooksPath silently disables guard (hence installer removes it, check-config flags it)" 1 || ok "stale hooksPath behaviour changed" 0
git config --unset core.hooksPath

echo "pass=$pass fail=$fail"; [ "$fail" = 0 ]
