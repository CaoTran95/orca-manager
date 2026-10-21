#!/usr/bin/env ruby
# Read-only: quyền sở hữu task record (docs/tasks/) giữa các feature worktree.
#   ownership.rb conflicts [--for KEY] [--paths-only]   xung đột claim; exit 1 nếu có ERROR
#   ownership.rb registry-paths KEY                       path KEY được main duyệt (owner hoặc grandfathered)
#   ownership.rb naming-owner PATH                        key sở hữu PATH theo tên (key dài nhất khớp)
#   ownership.rb staging-branches                         branch harness/* được main duyệt làm vùng staging Harness
#   ownership.rb validate [FILE]                          kiểm tra schema config/task-ownership.yaml
#
# Nguồn claim:
#   registry : main:config/task-ownership.yaml (bản đã commit) -> tasks.<path>.owner / grandfathered
#   owns     : front matter `owns:` trong file chính YYYY-MM-DD-<key>.md, đọc ở tip mọi branch feat/*
#              VÀ ở working copy của mọi worktree feat/* (kể cả chưa commit)
# ERROR  : >=2 key khai `owns:` cùng path; `owns:` khác owner của registry (không nằm trong grandfathered);
#          `owns:` khác key sở hữu theo tên.
# WARN   : nhiều key chỉ do registry (owner + grandfathered) hoặc owner_status còn `proposed`.
require "yaml"
require "json"
require "open3"
require "date"

def git(*a, dir: nil)
  o, s = Open3.capture2e("git", *(dir ? ["-C", dir] : []), *a)
  s.success? ? o : nil
end

COMMON = File.realpath(git("rev-parse", "--git-common-dir").to_s.strip.then { |c| File.expand_path(c) })
MAIN_ROOT = File.dirname(COMMON)
PATH_RE = %r{\Adocs/tasks/\d{4}-\d{2}-\d{2}-[A-Za-z0-9._-]+\.md\z}
PROTECTED_RE = %r{/(README|TEMPLATE|HANDOFF_TEMPLATE)\.md\z}

def load_yaml(text)
  YAML.safe_load(text.to_s, permitted_classes: [Date]) rescue nil
end

def registry(file = nil)
  text = file ? (File.read(file) rescue nil) : git("show", "main:config/task-ownership.yaml", dir: MAIN_ROOT)
  d = load_yaml(text)
  t = d.is_a?(Hash) ? d["tasks"] : nil
  t.is_a?(Hash) ? t : {}
end

def key_of_branch(b) = b.sub(%r{\Afeat/}, "").tr("/", "-")

def front_owns(text)
  return [] unless text =~ /\A---\n(.*?)\n---\n/m
  d = load_yaml($1)
  o = d.is_a?(Hash) ? d["owns"] : nil
  o.is_a?(Array) ? o.map(&:to_s) : []
end

def feature_branches
  (git("for-each-ref", "--format=%(refname:short)", "refs/heads/feat/", dir: MAIN_ROOT) || "").split("\n").reject(&:empty?)
end

def worktrees
  out = git("worktree", "list", "--porcelain", dir: MAIN_ROOT) || ""
  out.split("\n\n").map do |blk|
    h = {}
    blk.each_line { |l| k, v = l.chomp.split(" ", 2); h[k] = v }
    h
  end
end

def known_keys
  (feature_branches.map { |b| key_of_branch(b) } + registry.values.map { |v| v.is_a?(Hash) ? v["owner"].to_s : "" }).reject(&:empty?).uniq
end

def primary_re(key) = /\Adocs\/tasks\/\d{4}-\d{2}-\d{2}-#{Regexp.escape(key)}\.md\z/
def naming_re(key) = /\Adocs\/tasks\/\d{4}-\d{2}-\d{2}-#{Regexp.escape(key)}(-[A-Za-z0-9._-]+)?\.md\z/

def naming_owner(path)
  known_keys.select { |k| path =~ naming_re(k) }.max_by(&:length)
end

# [{path:, key:, kind: :owns|:registry_owner|:grandfathered, src:}]
def claims
  cl = []
  registry.each do |path, v|
    next unless v.is_a?(Hash)
    cl << { path: path, key: v["owner"].to_s, kind: :registry_owner, src: "registry" }
    Array(v["grandfathered"]).each { |k| cl << { path: path, key: k.to_s, kind: :grandfathered, src: "registry" } }
  end
  feature_branches.each do |b|
    key = key_of_branch(b)
    (git("ls-tree", "-r", "--name-only", b, "--", "docs/tasks", dir: MAIN_ROOT) || "").split("\n").grep(primary_re(key)).each do |prim|
      front_owns(git("show", "#{b}:#{prim}", dir: MAIN_ROOT)).each { |p| cl << { path: p, key: key, kind: :owns, src: "branch #{b}" } }
    end
  end
  worktrees.each do |w|
    br = w["branch"].to_s.sub(%r{\Arefs/heads/}, "")
    next unless br.start_with?("feat/") && w["worktree"]
    key = key_of_branch(br)
    Dir.glob(File.join(w["worktree"], "docs/tasks/*.md")).each do |f|
      rel = f.sub(w["worktree"] + "/", "")
      next unless rel =~ primary_re(key) && !File.symlink?(f)
      front_owns(File.read(f)).each { |p| cl << { path: p, key: key, kind: :owns, src: "worktree #{File.basename(w["worktree"])}" } }
    end
  end
  cl
end

def conflicts
  out = []
  claims.group_by { |c| c[:path] }.each do |path, cs|
    keys = cs.map { |c| c[:key] }.uniq
    owns = cs.select { |c| c[:kind] == :owns }
    reg_owner = cs.find { |c| c[:kind] == :registry_owner }
    gf = cs.select { |c| c[:kind] == :grandfathered }.map { |c| c[:key] }
    nm = naming_owner(path)
    detail = cs.map { |c| "#{c[:key]}(#{c[:kind]}@#{c[:src]})" }.uniq.join(", ")
    err = false
    err = true if owns.map { |c| c[:key] }.uniq.size > 1
    owns.each do |c|
      err = true if reg_owner && reg_owner[:key] != c[:key] && !gf.include?(c[:key])
      err = true if nm && nm != c[:key]
    end
    if err then out << ["ERROR", path, detail]
    elsif keys.size > 1 then out << ["WARN", path, "chồng quyền (registry): #{detail}"]
    end
  end
  out
end

case ARGV[0]
when "conflicts"
  fk = ARGV.include?("--for") ? ARGV[ARGV.index("--for") + 1] : nil
  rows = conflicts
  rows = rows.select { |_, _, d| d.include?("#{fk}(") } if fk
  if ARGV.include?("--paths-only")
    rows.select { |l, _, _| l == "ERROR" }.each { |_, p, _| puts p }
  else
    rows.each { |r| puts r.join("\t") }
  end
  exit(rows.any? { |l, _, _| l == "ERROR" } ? 1 : 0)
when "registry-paths"
  k = ARGV[1].to_s
  registry.each { |p, v| puts p if v.is_a?(Hash) && (v["owner"].to_s == k || Array(v["grandfathered"]).map(&:to_s).include?(k)) }
when "staging-branches"
  text = git("show", "main:config/task-ownership.yaml", dir: MAIN_ROOT)
  d = load_yaml(text)
  st = d.is_a?(Hash) ? d["harness_staging"] : nil
  st.each_key { |b| puts b } if st.is_a?(Hash)
when "naming-owner"
  o = naming_owner(ARGV[1].to_s)
  puts o if o
when "validate"
  file = ARGV[1] || File.join(MAIN_ROOT, "config/task-ownership.yaml")
  d = load_yaml(File.read(file))
  bad = []
  bad << "version phải là 2" unless d.is_a?(Hash) && d["version"] == 2
  t = d.is_a?(Hash) ? d["tasks"] : nil
  bad << "tasks phải là mapping" unless t.is_a?(Hash)
  (t || {}).each do |path, v|
    bad << "#{path}: path không hợp lệ" unless path =~ PATH_RE && path !~ PROTECTED_RE
    next bad << "#{path}: phải là mapping" unless v.is_a?(Hash)
    bad << "#{path}: thiếu owner" if v["owner"].to_s.empty?
    bad << "#{path}: owner_status phải là proposed|confirmed" unless %w[proposed confirmed].include?(v["owner_status"])
    bad << "#{path}: grandfathered phải là mảng" unless v["grandfathered"].nil? || v["grandfathered"].is_a?(Array)
    bad << "#{path}: owner nằm trong grandfathered" if Array(v["grandfathered"]).include?(v["owner"])
  end
  st = d.is_a?(Hash) ? d["harness_staging"] : nil
  bad << "harness_staging phải là mapping" unless st.nil? || st.is_a?(Hash)
  (st || {}).each do |b, v|
    bad << "harness_staging #{b}: tên phải dạng harness/<topic>" unless b =~ %r{\Aharness/[A-Za-z0-9._-]+\z}
    bad << "harness_staging #{b}: thiếu approved_by/reason" unless v.is_a?(Hash) && !v["reason"].to_s.empty?
  end
  bad.each { |b| puts "OWNERS #{b}" }
  warn_n = (t || {}).count { |_, v| v.is_a?(Hash) && v["owner_status"] == "proposed" }
  puts "WARN #{warn_n} task có owner_status=proposed (chờ user xác nhận)" if warn_n > 0
  exit(bad.empty? ? 0 : 1)
else
  warn "usage: ownership.rb conflicts [--for KEY] [--paths-only] | registry-paths KEY | naming-owner PATH | staging-branches | validate [FILE]"
  exit 2
end
