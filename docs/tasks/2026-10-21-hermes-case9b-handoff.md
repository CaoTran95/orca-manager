# Task Handoff: T2 — tách code chiến dịch từ a4f84b2

- Feature: case9b-marketing-processing | Task: T2 | Depends on: none
- Repo: hermes-agent (bidu-hermes-agent)
- Worktree: /Users/android/orca/workspaces/bidu-hermes-agent/case9b-marketing-processing (branch `feat/case9b-marketing-processing`, base origin/main 79c0b7c). Git sạch lúc giao.

## Mục tiêu
Commit `a4f84b2` ("bidu-cs 0.11.0: extend Case 9 to detach promotions and affiliate campaigns by list") gộp promotion và affiliate campaign. Hãy phân tích commit (`git show a4f84b2`), xác định phần chỉ liên quan **chiến dịch (affiliate campaign)**, và đưa riêng phần đó vào worktree này, tách khỏi phần promotion. Dùng plan `bidu/docs/plans/2026-10-20-case9b-hermes-tools.md` trong commit để hiểu ranh giới.

## Phạm vi được sửa
- Chỉ dưới `bidu/` trong worktree này (profiles/cs, evals/cs, docs/plans nếu cần).

## Acceptance criteria
- [ ] Phần diff trong worktree chỉ gồm logic/test/fixture/doc của chiến dịch; ghi rõ file/hàm nào thuộc chiến dịch, promotion, dùng chung.
- [ ] Nếu hàm dùng chung buộc phải kéo theo một phần promotion, giữ tối thiểu và nêu lý do.
- [ ] Test/eval liên quan chạy pass (tìm lệnh trong README `bidu/evals/cs` và CLAUDE.md).
- [ ] Commit trên branch này, message theo quy ước repo ([BIDU] ...), tách commit hợp lý.

## Không được làm
- Không rebase/merge/force-push/reset; không đụng worktree hay branch khác; không push; không merge vào branch bảo vệ.
- Không sửa `bidu_ops_mcp.py` ngoài phần cần tách; không đổi tool API hiện có ngoài phạm vi.
- Nếu ranh giới campaign/promotion không rõ, **hỏi coordinator bằng `ask`** thay vì đoán.

## Skill/rule
- Không có domain skill ở repo này. Đọc `AGENTS.md`, `CLAUDE.md` trong worktree. Không tạo skill.

## Báo cáo (<= 15 dòng)
1. Trạng thái: succeeded | failed | blocked
2. Ranh giới tách: file/hàm -> campaign | promotion | shared
3. Files changed + `git diff --stat`
4. Lệnh test + kết quả thật
5. Commit hash
6. Rủi ro/quyết định cần Leader duyệt
