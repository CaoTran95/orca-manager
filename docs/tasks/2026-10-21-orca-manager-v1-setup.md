# Task: Thiết lập Orca Manager V1

- Status: completed
- Feature key: orca-manager-v1-setup
- Created: 2026-10-21
- Updated: 2026-10-21
- Owner: AI / user

## Request

Chuẩn hóa Orca Manager V1: Claude Code là Leader, Orca CLI quản lý worktree/agent, Codex/Cursor là worker. Tạo repository catalog, skill registry, handoff, verification và state tracking. Người dùng yêu cầu commit trực tiếp vào `main`.

## Repositories and worktrees

| Repo | Base | Branch | Worktree path | Status |
| --- | --- | --- | --- | --- |
| Orca Manager | local `main` (không có remote) | `main` (người dùng chỉ định) | `/Users/android/orca/projects/Orca Manager` | in-progress |

Chỉ sửa tài liệu/cấu hình của chính Orca Manager; không chạm repo nghiệp vụ.

## Plan

- [x] Khảo sát git, AGENTS.md, docs, Orca CLI (`repo list`, `worktree list`, `terminal list`, `orchestration`, `skills`).
- [x] Xác minh skill thực tế trong từng repo.
- [x] `config/repositories.yaml`, `config/skill-registry.yaml`.
- [x] `docs/LEADER_PLAYBOOK.md`, `docs/tasks/HANDOFF_TEMPLATE.md`, cập nhật TEMPLATE/README/CLAUDE.md/AGENTS.md.
- [x] Kiểm thử config (parse YAML, đối chiếu path/skill tồn tại).
- [x] Commit.

## Progress

### 2026-10-21

- Orca CLI có sẵn `orchestration` (run/task/worker-start/check/gate) và skill `orchestration`, `orca-cli` (`orca skills get <name>`) -> tái sử dụng, không tạo skill quản trị mới.
- `--agent` của `worker-start` hỗ trợ `claude, codex, cursor, ...`.
- Domain skill thật chỉ có ở: android app, ecommerce-backend, bidu-mcp (và 2 file `create-page.md` dạng cursor skill ở admin/webapp). Các repo khác chưa có skill; ghi nhận thiếu, không tự tạo.
- Dòng `main` có `.serena/` untracked của người dùng: không đưa vào commit.

## Decisions and notes

- Base branch mặc định không cố định: theo từng repo trong `config/repositories.yaml`.
- Không hardcode path máy; resolve qua `orca repo show --repo name:<name>`.
- Codex/Cursor chưa xác minh tự nhận skill giống nhau -> handoff luôn ghi đường dẫn tuyệt đối-tương-đối skill để worker đọc trực tiếp.

## Handoff

- Commits: xem `git log` (docs+config V1 setup)
- Remote/MR: không có remote
- Untracked: `.serena/` (của người dùng, bỏ qua)
- Blockers: bản prompt của người dùng bị cắt ở mục 11; áp dụng quy trình Delegate -> Verify -> Correct -> Approve đã nêu.
- Next step: dùng playbook cho feature đầu tiên; người dùng duyệt base branch commerce-cronjob-backend (staging vs master) và bổ sung domain skill thiếu.

## Validation

~~~text
Command: ruby YAML.safe_load_file + đối chiếu với `orca repo list --json` và File.exist? cho mọi skill path
Result: repos=13 skills=12 bad=0 (mọi repo resolve được, mọi skill path tồn tại)
Chưa chạy: giao worker thật (không có feature để giao; tránh khởi chạy agent không cần thiết).
~~~
