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

## Update 2026-10-21 — Harness Setup: enforce leader and harness policies (mode SETUP, main)

- Thay rule cũ "origin/develop, fallback origin/main" bằng `baseRef` + `status` trong `config/repositories.yaml` (đổi tên trường `base_branch` -> `baseRef`); thiếu/chưa verified => hỏi user.
- AGENTS.md viết lại làm nguồn duy nhất; CLAUDE.md và `.cursor/rules` chỉ tóm tắt/trỏ về.
- Thêm mode SETUP/MONITOR/EXECUTE/REVIEW, vai trò Leader/Worker, xác minh dispatch, Harness ownership.
- Guard mới: `scripts/guard-harness.sh`, hooks pre-commit và pre-merge-commit; `scripts/check-config.sh` kiểm tra baseRef/status, rule lỗi thời, hooks.
- Validation: `scripts/check-config.sh` problems=0; guard kiểm tra trên clone tạm và worktree thật.
- Phát hiện: worktree `feat-orca-manager-task-workflow` đang có thay đổi docs/tasks của feature khác (case9*); chưa xử lý, chờ user.

## Update 2026-10-21 — Hoàn thiện Harness Guard (mode SETUP, main)

- Sửa lỗi bc62c96: `core.hooksPath` tuyệt đối trỏ `.githooks` im lặng mất hiệu lực khi di chuyển repo (đã tái hiện) -> thay bằng stub trong `<git-common-dir>/hooks` (`scripts/install-hooks.sh`), tự tìm main lúc chạy; xóa `.githooks/`.
- Guard v2: ownership = naming + `owns:` ở file chính (file mới) + `config/task-ownership.yaml` do main duyệt (file đã có/chéo); từ chối symlink/glob/template; `git status -z`; chỉ xét commit chưa có trong main; nội dung trùng main (merge đồng bộ) không bị chặn; `.serena/` bị chặn khi stage.
- Phát hiện: 2 feature worktree hiện có (content-translation-ai, orca-manager-task-workflow) đã commit task record con/chéo -> guard v1 báo vi phạm; grandfather vào `config/task-ownership.yaml`, cần user rà soát.
- Mới: `scripts/test-guard.sh` (25 ca trên clone tạm), `scripts/harness-status.sh`.
- Chưa kiểm chứng: Claude/Codex/Cursor thực sự nạp instruction nào khi mở trong feature worktree (suy ra từ cơ chế cwd, chưa chạy thử); Orca có tạo worktree bằng cách khác bỏ qua common-dir hooks hay không.

## Update 2026-10-21 — Ownership v2, xung đột claim, nguồn instruction (mode SETUP, main)

- `config/task-ownership.yaml` v2: mỗi task một `owner` + `owner_status` (proposed/confirmed) + `grandfathered`. Quyền hiệu lực giữ nguyên so với v1 (không xóa quyền, không sửa task record nào).
- Đề xuất owner (chờ user xác nhận, đều đang `proposed`): `case9-expanded`, `case9b-input-change`, `case9b-marketing-processing`, `orca-manager-task-workflow` -> owner `orca-manager-task-workflow`; `content-translation-ai` chỉ còn grandfathered cho `case9-expanded` và `orca-manager-task-workflow`. Bằng chứng: chỉ branch orca-manager-task-workflow có commit 6b1e988 (tách case9b) và 2 file case9b; bản case9-expanded ở content-translation-ai là bản trước khi tách.
- Phát hiện xung đột: `scripts/ownership.rb conflicts` (đọc `owns:` ở tip mọi branch feat/* và working copy mọi worktree + registry); guard từ chối `owns:` trùng/xung đột và naming lấn key dài hơn.
- Guard đọc thay đổi ròng so với điểm tách main (gồm nội dung từ commit merge); path có nội dung trùng một phiên bản từng có trên main thì hợp lệ.
- Nguồn commit 3e7d783 (reflog + trailer): Cursor worker (agent-monitor TUI) commit trực tiếp trên main lúc 11:13:46 để khôi phục `.githooks/` mà commit 38513a7 của chính Cursor lúc 11:13:07 đã xóa. Cùng git user, không reset/revert. Ghi nhận: worker đang ghi thẳng vào checkout main (trái ghi chú trong config/repositories.yaml).
- Probe instruction (read-only, hỏi trong cwd `feat-content-translation-ai`, không tool): Claude nạp CLAUDE.md của worktree (bản cũ, "fallback origin/main"), KHÔNG nạp AGENTS.md; Codex nạp AGENTS.md worktree (bản cũ); Cursor nạp .cursor rule + CLAUDE.md + AGENTS.md worktree (bản cũ). Không agent nào nạp Harness mới từ main.

## Update 2026-10-21 — Harness Sync (rebase), Worker Isolation, rà soát ownership (mode SETUP, main)

- `scripts/sync-harness.sh` (--check/--apply): rebase lên main thay cho merge; mô phỏng replay từng commit bằng `git merge-tree`; từ chối khi có thay đổi local, merge commit, commit đã push, thao tác dở dang, conflict; xác nhận bằng tên branch; ref sao lưu `refs/orca-sync-backup/*`; conflict thật thì `rebase --abort`. Không áp dụng cho feature worktree thật trong phiên này.
- Worker Isolation: `scripts/guard-dispatch.sh` (từ chối main/primary checkout/worktree Orca Manager cho task nghiệp vụ), staging `harness/<topic>` do user duyệt (`harness_staging`), `scripts/integrate-harness.sh` (validate trong staging rồi fast-forward), hook `commit-msg` chặn trailer Codex/Cursor trên main, cảnh báo main dirty trong `check-config.sh`. Probe env: Codex/Cursor không đặt biến nhận diện => không chặn theo danh tính được.
- Rà soát 4 task proposed (giữ `proposed`, không đổi `confirmed`, không gỡ grandfathered). Bằng chứng git:
  - case9-expanded: 3 commit ở orca-manager-task-workflow (8ef2a37 -> 6b1e988, bản split mới nhất), 2 commit ở content-translation-ai (8a70ee5, 9262fb9; bản trước khi tách); header "Feature key: case9-expanded" không khớp branch nào.
  - case9b-input-change, case9b-marketing-processing: chỉ có ở orca-manager-task-workflow (commit 6b1e988); marketing-processing đang có sửa local chưa commit ở chính worktree owner.
  - orca-manager-task-workflow: đặt tên chính là của orca-manager-task-workflow; content-translation-ai chỉ có bản sao (49c0dff).
  - Đề xuất: owner = orca-manager-task-workflow cho cả 4; giữ content-translation-ai grandfathered đến khi user duyệt gỡ. Lưu ý: case9* về nội dung thuộc Hermes, key chưa có branch riêng.
- Sự cố test: bản test đầu của `test-sync.sh` đã vô tình `git push` branch `feat/fp` về repo thật qua remote `origin` của clone; đã xóa branch `feat/fp` (commit test 392acdd, tôi tạo) và sửa test `git remote remove origin` ở cả hai bộ test.
