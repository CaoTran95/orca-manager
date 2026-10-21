#!/usr/bin/env bash
# Tóm tắt worktree và terminal agent của Orca.
# Dùng: scripts/orca-status.sh [feature-key] [--full-path] [--no-color]
set -euo pipefail

feature_key=""
full_path=0
no_color=0
for arg in "$@"; do
  case "$arg" in
    --full-path) full_path=1 ;;
    --no-color) no_color=1 ;;
    --help|-h)
      printf '%s\n' 'Usage: scripts/orca-status.sh [feature-key] [--full-path] [--no-color]'
      exit 0
      ;;
    *) feature_key="$arg" ;;
  esac
done

python3 - "$feature_key" "$full_path" "$no_color" <<'PY'
import json
import os
import shutil
import subprocess
import sys

feature_key, full_path, no_color = sys.argv[1], bool(int(sys.argv[2])), bool(int(sys.argv[3]))

def orca_json(*args):
    output = subprocess.check_output(["orca", *args, "--json"], text=True)
    return json.loads(output)["result"]

worktrees = orca_json("worktree", "list").get("worktrees", [])
terminals = orca_json("terminal", "list", "--limit", "500").get("terminals", [])
terminals_by_path = {}
for terminal in terminals:
    terminals_by_path.setdefault(terminal.get("worktreePath", ""), []).append(terminal)

def clean_branch(value):
    return value.replace("refs/heads/", "").replace("refs/remotes/origin/", "origin/")

def repo_name(worktree):
    if worktree.get("repo"):
        return worktree["repo"]
    path = worktree.get("path", "")
    return os.path.basename(os.path.dirname(path)) or "-"

def shorten(value, width):
    value = str(value or "-")
    if len(value) <= width:
        return value
    if width < 4:
        return value[:width]
    return value[:width - 3] + "..."

rows = []
for worktree in worktrees:
    branch = clean_branch(worktree.get("branch", ""))
    if feature_key and feature_key.lower() not in branch.lower():
        continue
    path = worktree.get("path", "")
    active_terminals = terminals_by_path.get(path, [])
    agent_names = sorted({t.get("agentIdentity") or "shell" for t in active_terminals})
    rows.append({
        "repo": repo_name(worktree),
        "branch": branch,
        "worktree": path if full_path else (os.path.basename(path) or path),
        "base": clean_branch(worktree.get("baseRef", "-")),
        "status": worktree.get("workspaceStatus", "-"),
        "agents": ",".join(agent_names) if agent_names else "-",
    })

rows.sort(key=lambda row: (row["repo"].lower(), row["branch"].lower(), row["worktree"].lower()))
if not rows:
    print(f"No worktrees matched: {feature_key}" if feature_key else "No Orca worktrees found")
    raise SystemExit(0)

headers = ["REPO", "BRANCH", "WORKTREE", "BASE", "STATUS", "AGENTS"]
keys = ["repo", "branch", "worktree", "base", "status", "agents"]
terminal_width = shutil.get_terminal_size((160, 24)).columns
widths = {"repo": 28, "branch": 30, "worktree": 32 if not full_path else 52, "base": 25, "status": 12, "agents": 18}
if terminal_width < 130:
    widths.update({"repo": 20, "branch": 25, "worktree": 24 if not full_path else 38, "base": 20, "status": 11, "agents": 14})

def paint(text, code):
    if no_color or not sys.stdout.isatty():
        return text
    return f"\033[{code}m{text}\033[0m"

def format_row(values):
    return "  ".join(shorten(value, widths[key]).ljust(widths[key]) for key, value in zip(keys, values))

print(paint(f"Orca worktrees: {len(rows)}" + (f"  |  filter: {feature_key}" if feature_key else ""), "1;36"))
print(format_row(headers))
print("  ".join("-" * widths[key] for key in keys))
for item in rows:
    line = format_row([item[key] for key in keys])
    if item["status"] in ("working", "active"):
        line = paint(line, "32")
    elif item["status"] == "in-progress":
        line = paint(line, "33")
    print(line)

print()
print("Tip: scripts/orca-status.sh case9")
print("     scripts/orca-status.sh content-translation-ai --full-path")
PY
