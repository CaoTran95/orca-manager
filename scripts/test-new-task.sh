#!/usr/bin/env bash
# Kiểm thử new-task.sh bằng Orca CLI GIẢ và repo tạm. Không chạm Orca thật, repo thật hay worktree thật.
# Dùng: scripts/test-new-task.sh   (exit 1 nếu có FAIL)
set -uo pipefail
SRC=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/newtask-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ if [ "$2" = 1 ]; then pass=$((pass+1)); echo "[PASS] $1"; else fail=$((fail+1)); echo "[FAIL] $1"; fi; }
chk(){ local n=$1; shift; "$@" >/dev/null 2>&1 && ok "$n" 1 || ok "$n" 0; }
nchk(){ local n=$1; shift; "$@" >/dev/null 2>&1 && ok "$n" 0 || ok "$n" 1; }
G="git -c user.email=t@t -c user.name=t"

# --- Orca Manager giả (clone của SRC, không remote) ---
git clone -q -b main "$SRC" "$T/mgr" || exit 2
cd "$T/mgr"; git remote remove origin; git config user.email t@t; git config user.name t
cp "$SRC"/scripts/*.sh "$SRC"/scripts/*.rb scripts/; cp "$SRC"/docs/tasks/TEMPLATE.md docs/tasks/ 2>/dev/null
# --- repo nghiệp vụ giả có remote ---
git init -q --bare "$T/biz-remote.git"; git init -q "$T/biz"; ( cd "$T/biz"; git config user.email t@t; git config user.name t; git checkout -q -b develop; git commit -q --allow-empty -m init; git remote add origin "$T/biz-remote.git"; git push -q origin develop; git fetch -q origin )
git init -q --bare "$T/bizc-remote.git"; git init -q "$T/bizc"; ( cd "$T/bizc"; git config user.email t@t; git config user.name t; git checkout -q -b staging; git commit -q --allow-empty -m init; git remote add origin "$T/bizc-remote.git"; git push -q origin staging; git fetch -q origin )
cat > config/repositories.yaml <<EOF
version: 1
repositories:
  - {id: orca-manager, name: "Orca Manager", selector: "name:Orca Manager", remote: null, kind: manager, baseRef: main, status: verified}
  - {id: biz, name: biz, selector: "name:biz", remote: "$T/biz-remote.git", kind: backend, baseRef: origin/develop, status: verified}
  - {id: bizc, name: bizc, selector: "name:bizc", remote: "$T/bizc-remote.git", kind: backend, baseRef: origin/staging, status: needs-confirmation}
  - {id: nobase, name: nobase, selector: "name:nobase", remote: null, kind: backend, status: verified}
EOF
git add -A; git commit -q -m base; scripts/install-hooks.sh >/dev/null
printf '[{"displayName":"Orca Manager","path":"%s"},{"displayName":"biz","path":"%s"},{"displayName":"bizc","path":"%s"},{"displayName":"nobase","path":"%s"}]' "$T/mgr" "$T/biz" "$T/bizc" "$T/biz" > "$T/repos.json"

# --- Orca CLI giả ---
cat > "$T/fake-orca" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
case "$1 $2" in
  "repo list") ruby -rjson -e 'puts JSON.generate({ok:true,result:{repos:JSON.parse(File.read(ENV["FAKE_REPOS"]))}})';;
  "worktree create")
    name=""; base=""; wtname=""
    while [ $# -gt 0 ]; do case "$1" in --repo) shift; name=${1#name:};; --name) shift; wtname=$1;; --base-branch) shift; base=$1;; esac; shift; done
    [ "${FAKE_FAIL_REPO:-}" = "$name" ] && { echo '{"ok":false,"error":"boom"}'; exit 1; }
    path=$(ruby -rjson -e 'puts JSON.parse(File.read(ENV["FAKE_REPOS"])).find{|r|r["displayName"]==ARGV[0]}["path"]' "$name")
    dir="$FAKE_WS/$name/$wtname"; br="feat/$wtname"; [ "${FAKE_BAD_BRANCH:-}" = "$name" ] && br="feat-other"; [ "${FAKE_NOPREFIX:-}" = "$name" ] && br="$wtname"
    git -C "$path" worktree add -q -b "$br" "$dir" "$base" || exit 1
    git -C "$dir" config user.email t@t; git -C "$dir" config user.name t
    printf '{"ok":true,"result":{"worktree":{"id":"repo-%s::%s","path":"%s","branch":"refs/heads/%s"}}}\n' "$name" "$dir" "$dir" "$br";;
  "worktree set") echo '{"ok":true}';;
  *) echo "unexpected: $*" >&2; exit 9;;
esac
EOF
chmod +x "$T/fake-orca"
export ORCA_BIN="$T/fake-orca" FAKE_LOG="$T/orca.log" FAKE_REPOS="$T/repos.json" FAKE_WS="$T/ws"; : > "$FAKE_LOG"
NT="$T/mgr/scripts/new-task.sh"; cd "$T/mgr"

# 1. plan không ghi gì
out=$("$NT" alpha --repo biz 2>&1); rc=$?
[ $rc = 0 ] && ok "plan ok (rc 0) for verified repo" 1 || ok "plan rc" 0
[[ "$out" == *"orca-manager"*"create"* && "$out" == *"biz"*"origin/develop"* ]] && ok "plan lists orca-manager + biz with baseRef" 1 || ok "plan content" 0
[ ! -d "$T/ws" ] && [ -z "$(git -C "$T/biz" branch --list 'feat/alpha')" ] && ok "plan creates nothing (no worktree, no branch)" 1 || ok "plan mutates" 0
! grep -q "worktree create" "$FAKE_LOG" && ok "plan never calls worktree create" 1 || ok "plan calls create" 0
# 2. blocked cases
nchk "unknown repo => BLOCKED rc1" "$NT" alpha --repo ghost
nchk "needs-confirmation => BLOCKED" "$NT" alpha --repo bizc
chk  "needs-confirmation + --confirm-base => plan ok" "$NT" alpha --repo bizc --confirm-base bizc
nchk "missing baseRef => BLOCKED" "$NT" alpha --repo nobase
nchk "apply refuses when any BLOCKED (nothing created)" "$NT" alpha --repo biz --repo ghost --apply
[ ! -d "$T/ws" ] && ok "blocked apply created nothing" 1 || ok "blocked apply created" 0
# 3. cú pháp
"$NT" Bad_Key --repo biz >/dev/null 2>&1; [ $? = 2 ] && ok "invalid key rc2" 1 || ok "invalid key" 0
"$NT" alpha >/dev/null 2>&1; [ $? = 2 ] && ok "missing --repo rc2" 1 || ok "missing repo" 0
"$NT" alpha --repo orca-manager >/dev/null 2>&1; [ $? = 2 ] && ok "listing orca-manager in --repo rejected" 1 || ok "orca-manager repo" 0
# 4. apply
out=$("$NT" alpha --repo biz --title "Alpha thử" --request "Yêu cầu thử" --apply 2>&1); rc=$?
[ $rc = 0 ] && ok "apply rc 0" 1 || { ok "apply rc" 0; echo "$out" | tail -5; }
[ -d "$T/ws/Orca Manager/alpha" ] && [ -d "$T/ws/biz/alpha" ] && ok "worktrees created for orca-manager and biz" 1 || ok "worktrees" 0
[ "$(git -C "$T/ws/biz/alpha" symbolic-ref --short HEAD)" = feat/alpha ] && ok "branch feat/alpha in biz" 1 || ok "branch biz" 0
git -C "$T/ws/biz/alpha" merge-base --is-ancestor origin/develop HEAD && ok "biz worktree based on origin/develop" 1 || ok "base" 0
tf="$T/ws/Orca Manager/alpha/docs/tasks/$(date +%Y-%m-%d)-alpha.md"
[ -f "$tf" ] && ok "task record created" 1 || ok "task record" 0
grep -q "Feature key: alpha" "$tf" && grep -q "# Task: Alpha thử" "$tf" && grep -q "Yêu cầu thử" "$tf" && ok "task record filled (key, title, request)" 1 || ok "task fill" 0
grep -q "| biz | origin/develop | feat/alpha | $T/ws/biz/alpha | ready |" "$tf" && grep -q "| orca-manager | main | feat/alpha |" "$tf" && ok "worktree table lists repo, baseRef, branch, path" 1 || ok "table" 0
[ -z "$(git -C "$T/ws/Orca Manager/alpha" status --porcelain)" ] && [ "$(git -C "$T/ws/Orca Manager/alpha" log -1 --format=%s)" = "docs: start alpha task record" ] && ok "task record committed (guard hook allowed it)" 1 || ok "task commit" 0
( cd "$T/ws/Orca Manager/alpha" && "$T/mgr/scripts/guard-harness.sh" --quiet ) && ok "guard OK in new orca-manager worktree" 1 || ok "guard" 0
! grep -q "orchestration\|terminal" "$FAKE_LOG" && ok "no dispatch/terminal calls made" 1 || ok "dispatch calls" 0
# 5. chạy lại: reuse, không tạo thêm, không đổi gì
echo keep > "$T/ws/biz/alpha/local.txt"; n_before=$(grep -c "worktree create" "$FAKE_LOG"); head_before=$(git -C "$T/ws/Orca Manager/alpha" rev-parse HEAD)
out=$("$NT" alpha --repo biz --apply 2>&1); rc=$?
[ $rc = 0 ] && [[ "$out" == *reuse* ]] && ok "re-run reuses worktrees" 1 || ok "re-run reuse" 0
[ "$(grep -c 'worktree create' "$FAKE_LOG")" = "$n_before" ] && ok "re-run creates no worktree" 1 || ok "re-run created" 0
[ "$(cat "$T/ws/biz/alpha/local.txt")" = keep ] && [ "$(git -C "$T/ws/Orca Manager/alpha" rev-parse HEAD)" = "$head_before" ] && ok "re-run leaves local files and history untouched" 1 || ok "re-run mutated" 0
# 6. branch tồn tại nhưng không có worktree
( cd "$T/biz" && git branch feat/beta develop )
nchk "existing branch without worktree => BLOCKED" "$NT" beta --repo biz
# 7. orca create lỗi giữa chừng
out=$(FAKE_FAIL_REPO=biz "$NT" gamma --repo biz --apply 2>&1); rc=$?
[ $rc = 1 ] && ok "create failure => rc1" 1 || ok "failure rc" 0
tg="$T/ws/Orca Manager/gamma/docs/tasks/$(date +%Y-%m-%d)-gamma.md"
[ -f "$tg" ] && grep -q "blocked" "$tg" && ok "failure recorded as blocked row in task record" 1 || ok "failure record" 0
[ ! -d "$T/ws/biz/gamma" ] && ok "no partial biz worktree after failure" 1 || ok "partial" 0
# 8. branch thực tế khác feat/<key>
out=$(FAKE_BAD_BRANCH=biz "$NT" delta --repo biz --apply 2>&1); rc=$?
[ $rc = 1 ] && [[ "$out" == *"khác feat/delta"* ]] && ok "branch mismatch stops without renaming" 1 || ok "mismatch" 0

# 9. Orca không thêm tiền tố feat/: đổi tên branch mới tạo
out=$(FAKE_NOPREFIX=biz "$NT" epsilon --repo biz --apply 2>&1); rc=$?
[ $rc = 0 ] && [ "$(git -C "$T/ws/biz/epsilon" symbolic-ref --short HEAD)" = feat/epsilon ] && ok "unprefixed branch from Orca renamed to feat/<key>" 1 || { ok "unprefixed rename" 0; echo "$out" | tail -4; }
echo "pass=$pass fail=$fail"; [ "$fail" = 0 ]
