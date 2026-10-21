# Task: Theo dõi AI agent gần thời gian thực

- Status: in-progress
- Feature key: agent-monitor
- Created: 2026-10-21
- Updated: 2026-10-21
- Owner: AI / user

## Request

Nâng cấp Orca Manager V1: một lệnh read-only trong Terminal để tổng hợp Claude/Codex/Cursor trên mọi repo và worktree. Gộp orchestration worker-list, terminal list, worktree ps và task file. Phân biệt worker orchestration với agent mở thủ công. Không suy đoán task ID, trạng thái đang làm hoặc hoàn thành khi thiếu dữ liệu. Hỗ trợ `--once` và `--watch 5`. Người dùng yêu cầu commit vào `main`, không push.

## Repositories and worktrees

| Repo | Base | Branch | Worktree path | Status |
| --- | --- | --- | --- | --- |
| Orca Manager | local `main` (không có remote; `git remote -v` rỗng) | `main` (người dùng chỉ định) | `/Users/android/orca/projects/Orca Manager` | in-progress |

Chỉ sửa script và tài liệu của Orca Manager. Không tạo/dừng agent, không sửa worktree nghiệp vụ.

## Tasks

| Task ID | Repo | Worktree | Worker/session | Depends on | Status | Evidence | Commit/MR |
| --- | --- | --- | --- | --- | --- | --- | --- |
| T1 | orca-manager | main | local shell | none | IN_PROGRESS | | |

## Acceptance criteria

- [ ] `scripts/agent-monitor.sh --once` đọc trạng thái Orca thật và in Agent, Repository, Worktree, Feature, Task, Session, Activity, Updated, Origin.
- [ ] Worker có trong `worker-list` hiện `orchestration`; agent không có record đó hiện `manual`.
- [ ] Task ID / activity / hoàn thành để trống (`-`) khi không có liên kết tường minh.
- [ ] `--watch 5` tự in lại khoảng mỗi 5 giây.
- [ ] Nhiều Run, phân trang và nguồn lỗi không làm script bịa dữ liệu.
- [ ] `docs/LEADER_PLAYBOOK.md` nêu cách dùng.
- [ ] Commit trên `main`, không push.

## Plan

- [x] Đọc `scripts/orca-status.sh` và schema JSON thật của Orca CLI.
- [ ] Ghi nhận worktree rồi thêm `scripts/agent-monitor.sh`.
- [ ] Cập nhật playbook.
- [ ] Chạy `--self-test`, `--once`, `--watch 5` trên trạng thái Orca thật.
- [ ] Commit trên `main`.

## Progress

### 2026-10-21 10:16

- Đã làm: khảo sát CLI. `orca-status.sh` chỉ ghép worktree list với terminal list.
- Bằng chứng/command: `orca worktree ps`, `terminal list`, `orchestration worker-list`, `run-list`, `task-list --run`.
- Kết quả: 2 Run (`run_702ee8c55062`, `run_legacy_local`); `task-list` không có `--run` trả `run_required`; worker-list có `page.nextCursor`; worktree ps/terminal list có `truncated` và `totalCount`. Pane và terminal cùng loại trong một worktree có thể nhiều hơn một, không có khóa chung để ghép.
- Việc tiếp theo: viết script read-only và kiểm thử.

## Decisions and notes

- Commit trên `main` vì người dùng chỉ định và repo không có remote, cùng cách với `orca-manager-v1-setup`.
- Không ghép pane `working`/`done` vào terminal khi cùng worktree có nhiều pane và nhiều terminal cùng loại.
- Task file chỉ gắn task ID khi cùng dòng bảng hoặc cùng dòng có handle terminal, và prefix chỉ khớp đúng một session đang thấy.

## Handoff

- Commits:
- Remote/MR: không có remote, không push
- Untracked hoặc local changes: `.serena/` của người dùng, không đưa vào commit
- Blockers:
- Next step: implement và kiểm thử
