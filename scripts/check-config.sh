#!/usr/bin/env bash
# Read-only: kiểm tra YAML, repo resolve được qua Orca, skill path tồn tại.
set -euo pipefail
cd "$(dirname "$0")/.."
ruby -ryaml -rjson -rdate -e '
L=->(f){YAML.safe_load_file(f,permitted_classes:[Date])}
r=L.("config/repositories.yaml"); s=L.("config/skill-registry.yaml")
paths=JSON.parse(`orca repo list --json`)["result"]["repos"].map{|x|[x["displayName"],x["path"]]}.to_h
ids=r["repositories"].map{|x|[x["id"],x]}.to_h
bad=0
r["repositories"].each{|x| (puts "NOREPO #{x["name"]}";bad+=1) unless paths[x["name"]]}
s["skills"].each{|k|
  x=ids[k["repo"]] or (puts "UNKNOWN repo #{k["repo"]}";bad+=1;next)
  base=paths[x["name"]] or next
  ([k["path"]]+(k["also_at"]||[])).each{|p| (puts "MISSING #{k["repo"]}:#{p}";bad+=1) unless File.exist?(File.join(base,p))}}
puts "repos=#{r["repositories"].size} skills=#{s["skills"].size} problems=#{bad}"
exit(bad.zero? ? 0 : 1)'
