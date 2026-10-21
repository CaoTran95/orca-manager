#!/usr/bin/env bash
# Read-only: tóm tắt worktree và terminal agent; lọc theo feature key nếu truyền đối số.
# Dùng: scripts/orca-status.sh [feature-key]
set -euo pipefail
key="${1:-}"
python3 - "$key" <<'P'
import json,subprocess,sys
key=sys.argv[1]
def j(*a): return json.loads(subprocess.check_output(['orca',*a,'--json']))['result']
wts=j('worktree','list')['worktrees']
terms={}
for t in j('terminal','list','--limit','200')['terminals']:
    terms.setdefault(t.get('worktreePath'),[]).append(t)
for w in wts:
    if key and key not in w['branch']: continue
    ts=terms.get(w['path'],[])
    ag=','.join(f"{t.get('agentIdentity') or 'shell'}:{t['handle'][:13]}" for t in ts) or '-'
    print(f"{w['branch'].replace('refs/heads/','')} | {w['path']} | base={w.get('baseRef')} | status={w.get('workspaceStatus')} | agents={ag}")
P
