# Task Handoff: <TASK-ID> — <mục tiêu một dòng>

Gửi cho worker (Codex/Cursor). Giữ ngắn; không dán lịch sử feature.

- Feature: <feature-key> | Task: <TASK-ID> | Depends on: <task-id hoặc none>
- Repo: <repo id trong config/repositories.yaml>
- Worktree: <path tuyệt đối> (branch `feat/<feature-key>`, base <ref>)
  Đã xác minh: repo, branch, path, `git status` sạch/ghi chú thay đổi sẵn có.

## Phạm vi được sửa
- <thư mục/file/module>

## Acceptance criteria
- [ ] <tiêu chí kiểm chứng được>

## Contract / dependency
- <API contract, task phụ thuộc, hoặc none>

## Skill/rule phải đọc (path trong worktree trên)
- <path từ config/skill-registry.yaml, đã xác minh tồn tại> | hoặc guidance: AGENTS.md, CLAUDE.md
- Không tạo/sửa skill. Nếu thiếu skill, dùng code + tài liệu có sẵn và báo thiếu.

## Không được làm
- Sửa ngoài phạm vi; reset/force-push/xóa worktree; merge vào branch bảo vệ; commit .env/credential.
- Đổi kiến trúc hoặc API contract: dừng và escalate.

## Test/build bắt buộc
- `<lệnh>` (nếu không chạy được, nêu lý do)

## Báo cáo (<= 15 dòng)
1. Trạng thái: succeeded | failed | blocked
2. Files changed (danh sách)
3. Lệnh test/build + kết quả thật (pass/fail, số test)
4. Commit hash (nếu commit)
5. Rủi ro/blocker/quyết định cần Leader duyệt
