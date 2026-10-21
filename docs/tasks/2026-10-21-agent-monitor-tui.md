# Task: Dashboard Terminal cho agent monitor

- Status: completed
- Feature key: agent-monitor-tui
- Created: 2026-10-21
- Updated: 2026-10-21
- Owner: AI / user

## Request

Nâng cấp `scripts/agent-monitor.sh` thành dashboard Terminal trên `main`. Chỉ đọc. Không tạo server, không sửa task nghiệp vụ, không push.

## Repositories and worktrees

| Repo | Base | Branch | Worktree path | Status |
| --- | --- | --- | --- | --- |
| Orca Manager | local `main` (không có remote) | `main` | `/Users/android/orca/projects/Orca Manager` | completed |

## Tasks

| Task ID | Repo | Worktree | Worker/session | Depends on | Status | Evidence | Commit/MR |
| --- | --- | --- | --- | --- | --- | --- | --- |
| T1 | orca-manager | main | local shell | none | DONE | self-test; --once rộng/hẹp; --json cli_commands=5; --watch 5 | local main, không push |

## Acceptance criteria

- [x] Dashboard một khung, refresh 5 giây, không in chồng bảng.
- [x] Summary và hai nhóm orchestration / manual.
- [x] Session id chỉ ở `--detail`.
- [x] `--once`, `--watch`, `--all`, `--feature`, `--json`.
- [x] Không suy agent đang chạy từ terminal còn sống; thiếu dữ liệu là UNKNOWN.
- [x] Mỗi refresh không gọi lại worker-list theo từng Run khi scope đã là all.

## Validation

~~~text
Command: scripts/agent-monitor.sh --self-test
Result: self-test ok

Command: COLUMNS=60 và COLUMNS=140 --once --all
Result: không dòng nào dài hơn chiều rộng. Cột Agent/Repository/Feature/Task/Worktree thẳng ở 140.
Worker codex: agent COMPLETED, worker SUCCEEDED, task REVIEW, completed, term CONNECTED.

Command: --json --once
Result: summary total=37 working=2 waiting_blocked=0 completed=28 interrupted_unknown=7 shown=9.
sources cli_commands=5 worker_scope=all extra_worker_queries=0 worker_pages=1.

Command: --once --all --feature case9b-marketing-processing
Result: Sessions 1, đúng worker Hermes.

Command: --watch 5 trong 8 giây
Result: exit 0, 2 khung lúc 11:12:15 và 11:12:20.
~~~

## Handoff

- Commits: trên `main`, không push
- Remote/MR: không có remote
- Untracked hoặc local changes khác: không đưa `.serena/`, `scripts/guard-harness.sh` hay file Harness đang sửa dở ngoài task này
- Blockers: không
- Next step: `scripts/agent-monitor.sh` hoặc `--once`
