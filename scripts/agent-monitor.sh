#!/usr/bin/env bash
# Read-only terminal dashboard for Claude/Codex/Cursor sessions.
# Does not create or stop agents, edit worktrees, change tasks, or call an AI.
# Usage:
#   scripts/agent-monitor.sh
#   scripts/agent-monitor.sh --once
#   scripts/agent-monitor.sh --watch 5
#   scripts/agent-monitor.sh --all --feature KEY --detail --json
#   scripts/agent-monitor.sh --self-test
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

pick() {
  local cmd
  for cmd in python3.11 python3.12 python3.13 python3.14 python3; do
    if command -v "$cmd" >/dev/null 2>&1 && "$cmd" -c 'import textual' >/dev/null 2>&1; then
      printf '%s\n' "$cmd"
      return 0
    fi
  done
  if command -v python3.11 >/dev/null 2>&1; then
    printf '%s\n' python3.11
    return 0
  fi
  printf '%s\n' python3
}

exec "$(pick)" "$DIR/agent_monitor.py" "$@"
