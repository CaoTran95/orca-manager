#!/usr/bin/env bash
# Read-only: kiểm tra YAML, baseRef/status, repo resolve qua Orca, skill path tồn tại,
# rule lỗi thời (mặc định develop/main) và guard hooks.
set -euo pipefail
cd "$(dirname "$0")/.."
ruby -ryaml -rjson -rdate -e '
L=->(f){YAML.safe_load_file(f,permitted_classes:[Date])}
r=L.("config/repositories.yaml"); s=L.("config/skill-registry.yaml")
paths=JSON.parse(`orca repo list --json`)["result"]["repos"].map{|x|[x["displayName"],x["path"]]}.to_h
ids=r["repositories"].map{|x|[x["id"],x]}.to_h
bad=0
r["repositories"].each{|x|
  (puts "NOREPO #{x["name"]}";bad+=1) unless paths[x["name"]]
  (puts "BADREF #{x["id"]}: thiếu baseRef";bad+=1) if x["baseRef"].to_s.empty?
  (puts "BADSTATUS #{x["id"]}: #{x["status"].inspect}";bad+=1) unless %w[verified needs-confirmation].include?(x["status"])
  (puts "LEGACY #{x["id"]}: còn base_branch";bad+=1) if x.key?("base_branch")}
(d=ids.keys.group_by{|i|i}.select{|_,v|v.size>1}).each{|k,_|puts "DUPID #{k}";bad+=1}
# Rule lỗi thời: mặc định/fallback develop-main ngoài config (task record cũ được bỏ qua).
stale=/fallback[^\n]{0,20}origin\/main|ưu tiên `?origin\/develop|origin\/develop hoặc origin\/main|newest origin\/develop|Dùng `origin\/develop` nếu/i
(%w[CLAUDE.md AGENTS.md .cursor/rules/orca-manager.mdc docs/LEADER_PLAYBOOK.md docs/ORCA_MANAGER_GUIDE.md docs/tasks/README.md docs/tasks/TEMPLATE.md docs/tasks/HANDOFF_TEMPLATE.md]).each{|f|
  File.readlines(f).each_with_index{|l,i| (puts "STALE #{f}:#{i+1}: #{l.strip[0,80]}";bad+=1) if l=~stale}}
s["skills"].each{|k|
  x=ids[k["repo"]] or (puts "UNKNOWN repo #{k["repo"]}";bad+=1;next)
  base=paths[x["name"]] or next
  ([k["path"]]+(k["also_at"]||[])).each{|p| (puts "MISSING #{k["repo"]}:#{p}";bad+=1) unless File.exist?(File.join(base,p))}}
hp=`git config --get core.hooksPath`.strip
exp=File.join(Dir.pwd,".githooks")
(puts "HOOKS core.hooksPath=#{hp.inspect}, cần #{exp}";bad+=1) unless hp==exp
%w[pre-commit pre-merge-commit].each{|h| (puts "HOOKFILE .githooks/#{h} thiếu/không chạy được";bad+=1) unless File.executable?(File.join(exp,h))}
puts "repos=#{r["repositories"].size} skills=#{s["skills"].size} problems=#{bad}"
exit(bad.zero? ? 0 : 1)'
