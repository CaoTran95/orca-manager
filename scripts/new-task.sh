#!/usr/bin/env bash
# Tạo task mới + worktree theo quy trình AGENTS.md mục 3. KHÔNG dispatch worker.
#   new-task.sh <feature-key> --repo <repo-id> [--repo <repo-id> ...] [--title "..."] [--request "..."]
#                [--confirm-base <repo-id> ...] [--apply]
# Mặc định chỉ in KẾ HOẠCH (không ghi gì). --apply mới tạo worktree + task record.
#   <repo-id>        id trong config/repositories.yaml (không liệt kê orca-manager: luôn được tạo kèm
#                    để chứa task record, branch feat/<key> từ main).
#   baseRef          lấy đúng từ config; thiếu hoặc status != verified => BLOCKED, trừ khi user đã xác nhận
#                    và Leader truyền --confirm-base <repo-id> (dùng đúng baseRef ghi trong config).
#   Tái sử dụng worktree đã có cho feat/<key>; branch đã tồn tại mà không có worktree => BLOCKED.
#   Không reset/xóa/ghi đè. Orca CLI: biến ORCA_BIN (mặc định `orca`).
# Exit: 0 = kế hoạch/áp dụng ok; 1 = có BLOCKED hoặc lỗi; 2 = sai cú pháp.
set -uo pipefail
ORCA=${ORCA_BIN:-orca}
key=""; repos=(); confirms=(); title=""; request=""; apply=0
while [ $# -gt 0 ]; do case "$1" in
  --repo) shift; repos+=("${1:-}");; --confirm-base) shift; confirms+=("${1:-}");;
  --title) shift; title=${1:-};; --request) shift; request=${1:-};; --apply) apply=1;;
  -*) echo "usage: $0 <feature-key> --repo <id> [--repo <id>...] [--title T] [--request R] [--confirm-base <id>] [--apply]" >&2; exit 2;;
  *) key=$1;; esac; shift; done
[[ "$key" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] && [ ${#key} -le 50 ] || { echo "new-task: feature-key phải là kebab-case (a-z0-9-), tối đa 50 ký tự" >&2; exit 2; }
[ ${#repos[@]} -gt 0 ] || { echo "new-task: cần ít nhất một --repo <id>" >&2; exit 2; }

common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P) || exit 2
main_root=$(dirname "$common")
today=$(date +%Y-%m-%d)
[ -f "$main_root/config/repositories.yaml" ] || { echo "new-task: thiếu config/repositories.yaml" >&2; exit 2; }

# id|name|baseRef|status|remote|path (path từ Orca; rỗng nếu Orca không biết repo)
rows=$(ORCA_BIN="$ORCA" IDS="$(printf '%s\n' orca-manager "${repos[@]}")" ruby -ryaml -rjson -rdate -e '
c=YAML.safe_load_file(File.join(ARGV[0],"config/repositories.yaml"),permitted_classes:[Date])["repositories"].map{|r|[r["id"],r]}.to_h
paths=(JSON.parse(`#{ENV["ORCA_BIN"]} repo list --json`)["result"]["repos"].map{|x|[x["displayName"],x["path"]]}.to_h rescue {})
ENV["IDS"].split("\n").uniq.each{|i| r=c[i]; (puts "#{i}|UNKNOWN"; next) unless r
  puts [i,r["name"],r["baseRef"],r["status"],r["remote"].to_s,paths[r["name"]].to_s].join("|")}' "$main_root")
[ -n "$rows" ] || { echo "new-task: không đọc được config/Orca" >&2; exit 1; }

blocked=0; plan=();
confirmed(){ local x; for x in "${confirms[@]:-}"; do [ "$x" = "$1" ] && return 0; done; return 1; }
for r in "${repos[@]}"; do [ "$r" = orca-manager ] && { echo "new-task: orca-manager luôn được tạo kèm, không liệt kê trong --repo" >&2; exit 2; }; done

# plan: id|action|baseRef|path|note   (action: create|reuse|BLOCKED)
while IFS='|' read -r id name base status remote path; do
  [ -n "$id" ] || continue
  if [ "$name" = UNKNOWN ]; then plan+=("$id|BLOCKED||-|không có trong config/repositories.yaml"); blocked=1; continue; fi
  if [ -z "$path" ] || [ ! -d "$path" ]; then plan+=("$id|BLOCKED|$base|-|Orca không biết repo '$name' hoặc path không tồn tại"); blocked=1; continue; fi
  if [ -z "$base" ]; then plan+=("$id|BLOCKED||-|thiếu baseRef trong config; hỏi user"); blocked=1; continue; fi
  if [ "$status" != verified ] && ! confirmed "$id"; then
    plan+=("$id|BLOCKED|$base|-|status=$status: hỏi user xác nhận baseRef $base rồi chạy lại với --confirm-base $id"); blocked=1; continue; fi
  br="feat/$key"
  ex=$(git -C "$path" worktree list --porcelain | awk -v b="refs/heads/$br" '/^worktree /{p=substr($0,10)} $1=="branch" && $2==b {print p}')
  if [ -n "$ex" ]; then
    d=$(git -C "$ex" status --porcelain | grep -vc '^?? \.serena/')
    plan+=("$id|reuse|$base|$ex|đã có worktree $br (local changes: $d)"); continue
  fi
  if git -C "$path" show-ref --verify --quiet "refs/heads/$br"; then
    plan+=("$id|BLOCKED|$base|-|branch $br đã tồn tại nhưng không có worktree; xử lý thủ công"); blocked=1; continue; fi
  if [ -n "$remote" ] && [[ "$base" == origin/* ]]; then note="sẽ fetch origin ${base#origin/}"
    git -C "$path" show-ref --verify --quiet "refs/remotes/$base" && note="$note (ref cục bộ hiện có)"
  else note="baseRef cục bộ (không remote)"
    git -C "$path" show-ref --verify --quiet "refs/heads/$base" || { plan+=("$id|BLOCKED|$base|-|không có branch cục bộ $base"); blocked=1; continue; }
  fi
  plan+=("$id|create|$base|(Orca chọn path)|$note")
done <<<"$rows"

echo "Feature: $key  (branch feat/$key)  ngày $today"
printf '%-24s %-8s %-18s %s\n' REPO ACTION BASEREF "PATH / GHI CHÚ"
for p in "${plan[@]}"; do IFS='|' read -r id act base path note <<<"$p"; printf '%-24s %-8s %-18s %s\n' "$id" "$act" "$base" "$path"; printf '%-24s %-8s %-18s   · %s\n' "" "" "" "$note"; done
echo "Task record: docs/tasks/$today-$key.md (trong worktree orca-manager)"
[ "$blocked" = 0 ] || { echo "new-task: có mục BLOCKED — dừng, không tạo gì."; exit 1; }
[ "$apply" = 1 ] || { echo "(kế hoạch; chạy lại với --apply để tạo)"; exit 0; }

# ---------------- apply ----------------
declare -a got_id got_path got_base got_status
create_wt(){ # id name path base  -> in ra path thực; trả 1 nếu lỗi
  local id=$1 name=$2 repo=$3 base=$4 remote=$5 out wt br
  if [ -n "$remote" ] && [[ "$base" == origin/* ]]; then git -C "$repo" fetch -q origin "${base#origin/}" || { echo "fetch origin ${base#origin/} thất bại cho $id" >&2; return 1; }; fi
  git -C "$repo" show-ref --verify --quiet "refs/remotes/$base" || git -C "$repo" show-ref --verify --quiet "refs/heads/$base" || { echo "baseRef $base không tồn tại ở $id sau khi fetch" >&2; return 1; }
  out=$("$ORCA" worktree create --repo "name:$name" --name "$key" --base-branch "$base" --no-parent --setup inherit --json 2>&1) || { echo "orca worktree create lỗi ($id): $out" >&2; return 1; }
  wt=$(printf '%s' "$out" | ruby -rjson -e 'w=JSON.parse(STDIN.read)["result"]["worktree"]; puts "#{w["id"]}\t#{w["path"]}\t#{w["branch"]}"' 2>/dev/null) || { echo "không đọc được kết quả create ($id): $out" >&2; return 1; }
  IFS=$'\t' read -r WT_ID WT_PATH br <<<"$wt"
  # Orca có thể không thêm tiền tố feat/ (tuỳ repo). Chỉ khi branch vừa tạo đúng bằng <key> và feat/<key> chưa tồn tại
  # mới đổi tên (branch mới tinh do chính script này tạo); mọi trường hợp khác dừng.
  if [ "${br#refs/heads/}" = "$key" ] && ! git -C "$repo" show-ref --verify --quiet "refs/heads/feat/$key"; then
    git -C "$WT_PATH" branch -m "$key" "feat/$key" || { echo "không đổi được tên branch $key -> feat/$key ở $WT_PATH" >&2; return 1; }
    br="refs/heads/feat/$key"; echo "ghi chú: Orca đặt branch '$key'; đã đổi thành feat/$key ($WT_PATH)"
  fi
  [ "${br#refs/heads/}" = "feat/$key" ] || { echo "branch thực tế '$br' khác feat/$key ở $WT_PATH — dừng, xử lý thủ công (không tự đổi tên)" >&2; return 1; }
  "$ORCA" worktree set --worktree "id:$WT_ID" --display-name "$key · $id" --json >/dev/null 2>&1 || echo "WARN: không đặt được display name cho $id" >&2
  return 0
}

mgr_path=""; mgr_new=0
IFS='|' read -r _ act base path _ <<<"${plan[0]}"
IFS='|' read -r _ mname mbase _ mremote mrepo <<<"$(printf '%s\n' "$rows" | head -1)"
if [ "$act" = reuse ]; then mgr_path=$path
else create_wt orca-manager "$mname" "$mrepo" "$mbase" "$mremote" || { echo "new-task: dừng; chưa tạo gì thêm." >&2; exit 1; }; mgr_path=$WT_PATH; mgr_new=1; fi

i=0; created=()
for p in "${plan[@]:1}"; do
  IFS='|' read -r id act base path note <<<"$p"
  line=$(printf '%s\n' "$rows" | awk -F'|' -v i="$id" '$1==i')
  IFS='|' read -r _ name _ _ remote repo <<<"$line"
  if [ "$act" = reuse ]; then got_path+=("$path"); else
    create_wt "$id" "$name" "$repo" "$base" "$remote" || { echo "new-task: dừng ở $id. Đã tạo trước đó: ${created[*]:-chỉ orca-manager}. Task record ghi blocker." >&2; failed=$id; break; }
    got_path+=("$WT_PATH"); created+=("$id")
  fi
  got_id+=("$id"); got_base+=("$base"); got_status+=("$([ "$act" = reuse ] && echo reused || echo ready)")
done

# task record từ TEMPLATE.md (không ghi đè nếu đã có)
tf="$mgr_path/docs/tasks/$today-$key.md"
if [ -e "$tf" ]; then echo "task record đã có, giữ nguyên: $tf"; else
  mkdir -p "$mgr_path/docs/tasks"
  TITLE="${title:-$key}" REQ="${request:-<mô tả yêu cầu và phạm vi>}" KEY="$key" TODAY="$today" \
  IDS="$(printf '%s\n' "${got_id[@]:-}")" PATHS="$(printf '%s\n' "${got_path[@]:-}")" BASES="$(printf '%s\n' "${got_base[@]:-}")" STATS="$(printf '%s\n' "${got_status[@]:-}")" \
  FAIL="${failed:-}" MGR="$mgr_path" ruby -e '
t=File.read(File.join(ARGV[0],"docs/tasks/TEMPLATE.md"))
ids=ENV["IDS"].split("\n");paths=ENV["PATHS"].split("\n");bases=ENV["BASES"].split("\n");st=ENV["STATS"].split("\n")
rows=["| orca-manager | main | feat/#{ENV["KEY"]} | #{ENV["MGR"]} | ready |"]
ids.each_index{|i| rows<<"| #{ids[i]} | #{bases[i]} | feat/#{ENV["KEY"]} | #{paths[i]} | #{st[i]} |"}
rows<<"| (chưa tạo: #{ENV["FAIL"]}) | | | | blocked |" unless ENV["FAIL"].to_s.empty?
t=t.sub("# Task: <task title>","# Task: #{ENV["TITLE"]}").sub("- Status: planned","- Status: planned").sub("<feature-key>",ENV["KEY"])
t=t.sub("Feature key: <feature-key>","Feature key: #{ENV["KEY"]}") if t.include?("Feature key: <feature-key>")
t=t.gsub("YYYY-MM-DD",ENV["TODAY"]).sub("Mô tả ngắn yêu cầu và phạm vi được người dùng giao.",ENV["REQ"])
t=t.sub(/^\| <repo> \|.*\n/,rows.join("\n")+"\n")
print t' "$main_root" >"$tf"
  ( cd "$mgr_path" && git add -- "docs/tasks/$today-$key.md" && git commit -q -m "docs: start $key task record" ) && echo "task record: $tf (đã commit)" || echo "WARN: task record đã ghi nhưng chưa commit: $tf" >&2
fi
echo; echo "== Kết quả"; echo "orca-manager  $mgr_path  $([ $mgr_new = 1 ] && echo created || echo reused)"
for n in "${!got_id[@]}"; do echo "${got_id[$n]}  ${got_path[$n]}  ${got_status[$n]}"; done
[ -z "${failed:-}" ] || exit 1
echo "Bước tiếp: điền acceptance criteria và task table trong task record, chọn skill (config/skill-registry.yaml), rồi scripts/guard-dispatch.sh <worktree> trước khi dispatch."
