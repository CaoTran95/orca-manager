# Task: Theo dõi AI agent gần thời gian thực

- Status: completed
- Feature key: agent-monitor
- Created: 2026-10-21
- Updated: 2026-10-21
- Owner: AI / user

## Request

Nâng cấp Orca Manager V1: một lệnh read-only trong Terminal để tổng hợp Claude/Codex/Cursor trên mọi repo và worktree. Gộp orchestration worker-list, terminal list, worktree ps và task file. Phân biệt worker orchestration với agent mở thủ công. Không suy đoán task ID, trạng thái đang làm hoặc hoàn thành khi thiếu dữ liệu. Hỗ trợ `--once` và `--watch 5`. Người dùng yêu cầu commit vào `main`, không push.

## Repositories and worktrees

| Repo | Base | Branch | Worktree path | Status |
| --- | --- | --- | --- | --- |
| Orca Manager | local `main` (không có remote; `git remote -v` rỗng) | `main` (người dùng chỉ định) | `/Users/android/orca/projects/Orca Manager` | completed |

Chỉ sửa script và tài liệu của Orca Manager. Không tạo/dừng agent, không sửa worktree nghiệp vụ.

## Tasks

| Task ID | Repo | Worktree | Worker/session | Depends on | Status | Evidence | Commit/MR |
| --- | --- | --- | --- | --- | --- | --- | --- |
| T1 | orca-manager | main | local shell | none | DONE | self-test ok; --once trên Orca thật; --watch 5 in 3 snapshot | local main, không push |

## Acceptance criteria

- [x] `scripts/agent-monitor.sh --once` đọc trạng thái Orca thật và in Agent, Repository, Worktree, Feature, Task, Session, Activity, Updated, Origin.
- [x] Worker có trong `worker-list` hiện `orchestration`; agent không có record đó hiện `manual`.
- [x] Task ID / activity / hoàn thành để trống (`-`) khi không có liên kết tường minh.
- [x] `--watch 5` tự in lại khoảng mỗi 5 giây.
- [x] Nhiều Run, phân trang và nguồn lỗi không làm script bịa dữ liệu.
- [x] `docs/LEADER_PLAYBOOK.md` nêu cách dùng.
- [x] Commit trên `main`, không push.

## Plan

- [x] Đọc `scripts/orca-status.sh` và schema JSON thật của Orca CLI.
- [x] Ghi nhận worktree rồi thêm `scripts/agent-monitor.sh`.
- [x] Cập nhật playbook.
- [x] Chạy `--self-test`, `--once`, `--watch 5` trên trạng thái Orca thật.
- [x] Commit trên `main`.

## Progress

### 2026-10-21 10:16

- Đã làm: khảo sát CLI. `orca-status.sh` chỉ ghép worktree list với terminal list.
- Bằng chứng/command: `orca worktree ps`, `terminal list`, `orchestration worker-list`, `run-list`, `task-list --run`.
- Kết quả: 2 Run (`run_702ee8c55062`, `run_legacy_local`); `task-list` không có `--run` trả `run_required`; worker-list có `page.nextCursor`; worktree ps/terminal list có `truncated` và `totalCount`. Pane và terminal cùng loại trong một worktree có thể nhiều hơn một, không có khóa chung để ghép.

### 2026-10-21 10:53

- Đã làm: `scripts/agent-monitor.sh`, mục theo dõi trong `docs/LEADER_PLAYBOOK.md`.
- Bằng chứng/command: xem Validation.
- Kết quả: snapshot thật có 37 agent, 1 orchestration (`term_322b3f65-02db-41c6-a68d-12f66bf4d129`, task T2 và `task_76912f16db8b`), 36 manual. Hai Claude trên `feat-translate-ai` để activity `-` kèm warning không khớp duy nhất.
- Việc tiếp theo: commit trên main, không push.

## Validation

~~~text
Command: scripts/agent-monitor.sh --self-test
Result: self-test ok

Command: scripts/agent-monitor.sh --once
Result: exit 0. rows=37 orchestration=1 manual=36. sources runs=2 run_pages=1 workers=1 worker_pages=3 tasks=1 terminals=44 worktree_ps=40.
Worker codex: Origin=orchestration, Task=T2 (status=REVIEW), task_76912f16db8b (status=completed), Activity=pane:done activity:unknown worker:succeeded.
Hai claude bidu-ai-backend feat/translate-ai: Activity=-. Warning: không gán activity (2 pane và 2 terminal).
Không có chuỗi title:.

Command: scripts/agent-monitor.sh --watch 5 (SIGINT sau 12s)
Result: exit 0. 3 snapshot, mốc header 10:29:53, 10:29:59, 10:30:03 +0700 (chu kỳ 5s, giây hiển thị làm tròn).

Command: scripts/agent-monitor.sh ; --watch ; --watch 0 ; --watch -5 ; PATH=/usr/bin:/bin --once
Result: exit 2. Thiếu orca in "không tìm thấy lệnh orca".

Command: orca orchestration run-list --limit 1 --json, rồi --cursor của trang 1
Result: trang 1 run_702ee8c55062, trang 2 run_legacy_local, nextCursor trang 2 null.
~~~

## Decisions and notes

- Commit trên `main` vì người dùng chỉ định và repo không có remote, cùng cách với `orca-manager-v1-setup`.
- Không ghép pane `working`/`done` vào terminal khi cùng worktree có nhiều pane và nhiều terminal cùng loại.
- Task file chỉ gắn task ID khi cùng dòng bảng hoặc cùng dòng có handle terminal, và prefix chỉ khớp đúng một session đang thấy.

## Handoff

- Commits: trên `main` sau commit này
- Remote/MR: không có remote, không push
- Untracked hoặc local changes: `.serena/` của người dùng, không đưa vào commit
- Blockers: không
- Next step: dùng `scripts/agent-monitor.sh --once` hoặc `--watch 5` khi cần trạng thái agent
