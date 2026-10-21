#!/usr/bin/env bash
# Kiểm thử sync-harness.sh (rebase), guard-dispatch.sh, branch harness/* staging, integrate-harness.sh
# và hook commit-msg trên clone TẠM. Không chạm repo thật hay feature worktree.
# Dùng: scripts/test-sync.sh   (exit 1 nếu có FAIL)
set -uo pipefail
SRC=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/sync-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ if [ "$2" = 1 ]; then pass=$((pass+1)); echo "[PASS] $1"; else fail=$((fail+1)); echo "[FAIL] $1"; fi; }
chk(){ local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name" 1; else ok "$name" 0; fi; }
nchk(){ local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name" 0; else ok "$name" 1; fi; }

mkdir "$T/r"; git clone -q -b main "$SRC" "$T/r/main" || exit 2
cd "$T/r/main" || exit 2
git config user.email t@t; git config user.name t
git remote remove origin   # tuyệt đối không để test push về repo thật
cp "$SRC"/scripts/*.sh "$SRC"/scripts/*.rb scripts/; cp "$SRC"/config/*.yaml config/
printf 'version: 2\nharness_staging:\n  harness/fix:\n    reason: "test approved"\ntasks: {}\n' > config/task-ownership.yaml
git add -A; git commit -qm base --allow-empty >/dev/null 2>&1; scripts/install-hooks.sh >/dev/null
M="$T/r/main"; SYNC="$M/scripts/sync-harness.sh"; DISP="$M/scripts/guard-dispatch.sh"; INT="$M/scripts/integrate-harness.sh"
mkwt(){ (cd "$M" && git worktree add -q "../$1" -b "$2" main && cd "../$1" && git config user.email t@t && git config user.name t); }
mainmove(){ (cd "$M"; echo "$1" >> README_main_$1.txt 2>/dev/null; printf 'x\n' > "docs/tasks/2026-10-22-mm$1.md"; git add -A; git commit -qm "main moves $1" >/dev/null 2>&1); }

# ---------- 1. Sync: nhánh sạch ----------
mkwt fa feat/fa; cd "$T/r/fa"; echo a > docs/tasks/2026-10-22-fa.md; git add -A; git commit -qm fa-1 >/dev/null 2>&1
mainmove 1
head_before=$(git rev-parse HEAD)
o=$("$SYNC" --check --worktree "$T/r/fa" 2>&1); [[ "$o" == SAFE* ]] && ok "check: SAFE for clean branch behind main (simulated replay)" 1 || ok "check SAFE" 0
cd "$M"
nchk "apply refuses wrong confirm" "$SYNC" --apply --worktree "$T/r/fa" --confirm wrong
[ "$(git -C "$T/r/fa" rev-parse HEAD)" = "$head_before" ] && ok "wrong confirm leaves HEAD untouched" 1 || ok "wrong confirm HEAD" 0
nchk "apply refuses with no TTY and no --confirm" bash -c "'$SYNC' --apply --worktree '$T/r/fa' </dev/null"
chk "apply rebases with matching --confirm" "$SYNC" --apply --worktree "$T/r/fa" --confirm feat/fa
[ -z "$(git -C "$T/r/fa" rev-list --merges main..HEAD)" ] && git -C "$T/r/fa" merge-base --is-ancestor main HEAD && ok "result is linear and contains main" 1 || ok "linear" 0
[ -n "$(git -C "$T/r/fa" for-each-ref refs/orca-sync-backup/feat/fa)" ] && ok "backup ref created" 1 || ok "backup ref" 0
[ "$(git -C "$T/r/fa" for-each-ref --format='%(objectname)' refs/orca-sync-backup/feat/fa | head -1)" = "$head_before" ] && ok "backup ref points to pre-rebase HEAD" 1 || ok "backup target" 0
cmp -s "$T/r/fa/AGENTS.md" "$M/AGENTS.md" && ok "Harness file now equals main after rebase" 1 || ok "AGENTS equal" 0
o=$("$SYNC" --check --worktree "$T/r/fa" 2>&1); [[ "$o" == *"CURRENT"* ]] && ok "check: CURRENT after sync" 1 || ok "CURRENT" 0
cd "$T/r/fa"; chk "guard OK on synced branch" "$M/scripts/guard-harness.sh" --quiet

# ---------- 2. Sync: dirty ----------
mkwt fb feat/fb; mainmove 2; echo dirty > "$T/r/fb/docs/tasks/2026-10-22-fb.md"
o=$("$SYNC" --check --worktree "$T/r/fb" 2>&1); [[ "$o" == *"UNSAFE"* ]] && ok "check: UNSAFE when local changes" 1 || ok "UNSAFE dirty" 0
cd "$M"; nchk "apply refuses dirty worktree" "$SYNC" --apply --worktree "$T/r/fb" --confirm feat/fb
[ "$(cat "$T/r/fb/docs/tasks/2026-10-22-fb.md")" = dirty ] && [ -z "$(git -C "$T/r/fb" stash list)" ] && ok "dirty file kept, no stash created" 1 || ok "dirty kept" 0

# ---------- 3. Sync: merge commit ----------
mkwt fm feat/fm; cd "$T/r/fm"; echo 1 > docs/tasks/2026-10-22-fm.md; git add -A; git commit -qm fm1 >/dev/null 2>&1
git checkout -q -b fmside main; git config core.hooksPath /nonexistent; echo s > docs/tasks/2026-10-22-fm-side.md; git add -A; git commit -qm side >/dev/null 2>&1; git checkout -q feat/fm
git merge -q --no-ff --no-edit fmside >/dev/null 2>&1; git config --unset core.hooksPath; mainmove 3; cd "$M"
o=$("$SYNC" --check --worktree "$T/r/fm" 2>&1); [[ "$o" == *"merge commit"* ]] && ok "check: UNSAFE when branch has merge commits" 1 || ok "UNSAFE merge" 0
nchk "apply refuses branch with merge commits" "$SYNC" --apply --worktree "$T/r/fm" --confirm feat/fm

# ---------- 4. Sync: conflict ----------
mkwt fc feat/fc; cd "$T/r/fc"; echo feature > docs/tasks/2026-10-22-fc.md; git add -A; git commit -qm fc1 >/dev/null 2>&1
(cd "$M"; echo main > docs/tasks/2026-10-22-fc.md; git add -A; git commit -qm "main adds fc file" >/dev/null 2>&1); cd "$M"
fc_head=$(git -C "$T/r/fc" rev-parse HEAD)
o=$("$SYNC" --check --worktree "$T/r/fc" 2>&1); [[ "$o" == *"conflict khi replay"* ]] && ok "check: predicts conflict via per-commit replay" 1 || ok "predict conflict" 0
nchk "apply refuses conflicting branch" "$SYNC" --apply --worktree "$T/r/fc" --confirm feat/fc
[ "$(git -C "$T/r/fc" rev-parse HEAD)" = "$fc_head" ] && [ -z "$(git -C "$T/r/fc" status --porcelain)" ] && ok "conflicting branch left untouched (no overwrite)" 1 || ok "conflict untouched" 0

# ---------- 5. Sync: đã push ----------
git init -q --bare "$T/remote.git"; mkwt fp feat/fp; cd "$T/r/fp"; echo p > docs/tasks/2026-10-22-fp.md; git add -A; git commit -qm fp1 >/dev/null 2>&1
git remote add origin "$T/remote.git"; git push -q -u origin feat/fp >/dev/null 2>&1; mainmove 5; cd "$M"
o=$("$SYNC" --check --worktree "$T/r/fp" 2>&1); [[ "$o" == *"force-push"* ]] && ok "check: UNSAFE when commits already pushed" 1 || ok "UNSAFE pushed" 0
nchk "apply refuses pushed branch (no force-push)" "$SYNC" --apply --worktree "$T/r/fp" --confirm feat/fp

# ---------- 6. Sync: phạm vi ----------
cd "$T/r/fa"; nchk "apply refuses outside main checkout" "$SYNC" --apply --worktree "$T/r/fa" --confirm feat/fa
cd "$M"; nchk "apply refuses to rebase main itself" "$SYNC" --apply --worktree "$M" --confirm main

# ---------- 7. Dispatch preflight ----------
git init -q "$T/biz"; (cd "$T/biz" && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m i && git worktree add -q ../biz-feat -b feat/x)
export ORCA_GUARD_PRIMARY_PATHS="$T/biz"
chk  "dispatch: linked business worktree OK" "$DISP" "$T/biz-feat"
nchk "dispatch: registered primary checkout refused" "$DISP" "$T/biz"
nchk "dispatch: Orca Manager main refused" "$DISP" "$M"
nchk "dispatch: Orca Manager feature worktree refused for business task" "$DISP" "$T/r/fa"
nchk "dispatch: harness task at feat/* refused" "$DISP" "$T/r/fa" --kind harness
mkwt hx harness/unapproved; mkwt hf harness/fix
nchk "dispatch: unapproved harness/* refused" "$DISP" "$T/r/hx" --kind harness
chk  "dispatch: approved harness/fix OK for harness kind" "$DISP" "$T/r/hf" --kind harness
nchk "dispatch: approved harness/fix refused for business kind" "$DISP" "$T/r/hf"
(cd "$T/biz-feat" && git checkout -q --detach); nchk "dispatch: detached HEAD refused" "$DISP" "$T/biz-feat"
nchk "dispatch: non-git path refused" "$DISP" "$T"
unset ORCA_GUARD_PRIMARY_PATHS

# ---------- 8. Staging guard + commit-msg ----------
cd "$T/r/hf"; echo staged >> AGENTS.md; echo y > scripts/new-tool.sh; chk "guard: approved harness/fix may edit Harness" "$M/scripts/guard-harness.sh" --quiet
git add -A; chk "hook: commit of Harness on approved staging allowed" git commit -qm "harness change" -m "Co-authored-by: Cursor <cursoragent@cursor.com>"
cd "$T/r/hx"; echo bad >> AGENTS.md; nchk "guard: unapproved harness/* may NOT edit Harness" "$M/scripts/guard-harness.sh" --quiet; git checkout -q -- AGENTS.md
cd "$M"; echo "more" >> docs/tasks/README.md; git add docs/tasks/README.md
nchk "commit-msg: main rejects Co-authored-by Cursor" git commit -qm "x" -m "Co-authored-by: Cursor <cursoragent@cursor.com>"
nchk "commit-msg: main rejects Co-authored-by Codex" git commit -qm "x" -m "Co-authored-by: Codex <codex@openai.com>"
chk  "commit-msg: main accepts Claude trailer" git commit -qm "main ok" -m "Co-Authored-By: Claude <noreply@anthropic.com>"

# ---------- 9. Integrate ----------
mkwt hy harness/unreg; cd "$T/r/hy"; echo z >> AGENTS.md; git add -A; git config core.hooksPath /nonexistent; git commit -qm z >/dev/null 2>&1; git config --unset core.hooksPath; cd "$M"
nchk "integrate: unapproved branch refused" "$INT" harness/unreg --confirm harness/unreg
nchk "integrate: refused when main moved past staging (needs sync)" "$INT" harness/fix --confirm harness/fix
chk  "sync apply works for harness/* staging worktree" "$SYNC" --apply --worktree "$T/r/hf" --confirm harness/fix
nchk "integrate: wrong confirm refused" "$INT" harness/fix --confirm nope
echo dirty > "$T/r/hf/scratch.txt"; nchk "integrate: dirty staging worktree refused" "$INT" harness/fix --confirm harness/fix; rm "$T/r/hf/scratch.txt"
main_before=$(git rev-parse HEAD)
if "$INT" harness/fix --confirm harness/fix >"$T/int.log" 2>&1; then
  ok "integrate: fast-forwards main after validation" 1
  [ "$(git rev-parse HEAD)" = "$(git rev-parse harness/fix)" ] && git merge-base --is-ancestor "$main_before" HEAD && ok "main == staging tip, history preserved" 1 || ok "ff result" 0
else ok "integrate: fast-forwards main after validation" 0; tail -8 "$T/int.log"; fi

echo "pass=$pass fail=$fail"; [ "$fail" = 0 ]
