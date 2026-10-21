# Task: Hermes Case 9b — tách code chiến dịch từ a4f84b2

- Status: IN_PROGRESS
- Feature key: case9b-marketing-processing
- Created: 2026-10-21
- Updated: 2026-10-21
- Owner: Claude Leader / Codex worker

## Request

Tách phần code liên quan **chiến dịch (affiliate campaign)** khỏi commit `a4f84b2` ([BIDU] bidu-cs 0.11.0: extend Case 9 detach promotions and affiliate campaigns) sang worktree riêng; không rebase/cherry-pick nguyên commit nếu làm lẫn phần promotion.

## Repositories and worktrees

| Repo | Base | Branch | Worktree path | Status |
| --- | --- | --- | --- | --- |
| bidu-hermes-agent (`hermes-agent`) | origin/main (`79c0b7c`) | `feat/case9b-marketing-processing` | `/Users/android/orca/workspaces/bidu-hermes-agent/case9b-marketing-processing` | ready, git sạch (đã có sẵn, không tạo lại) |

Nguồn commit: `a4f84b2` nằm trên `feat/bidu-cs-case9-extend` (13 file, +2483/-20, tập trung `bidu/profiles/cs/mcp/bidu_ops_mcp.py`, `bidu/evals/cs/*`, plan `bidu/docs/plans/2026-10-20-case9b-hermes-tools.md`).

## Tasks

| Task ID | Repo | Worktree | Worker/session | Depends on | Status | Evidence | Commit/MR |
| --- | --- | --- | --- | --- | --- | --- | --- |
| T2 | hermes-agent | case9b-marketing-processing | codex · term_322b3f65 · dispatch ctx_56847c551fe2 | none | IN_PROGRESS | dispatched 2026-10-21T03:13Z | |

## Acceptance criteria

- [ ] Worktree chỉ chứa phần chiến dịch của a4f84b2 (ranh giới ghi trong báo cáo worker); không lẫn phần promotion trừ khi phụ thuộc bắt buộc và được nêu rõ.
- [ ] Test/eval liên quan của `bidu/evals/cs` chạy được; báo cáo lệnh + kết quả thật.
- [ ] Không đụng ngoài `bidu/`; không đổi nhánh/worktree khác.

## Decisions and notes

- Giả định của Leader: worktree này là "Task 2 Hermes" (worktree mới duy nhất, sạch, tên khớp case9b). Cần người dùng đính chính nếu sai.
- Skill: repo hermes-agent không có domain skill (registry). Guidance: AGENTS.md, CLAUDE.md.
- Retry tối đa 2 vòng (playbook).

## Handoff

- Handoff: docs/tasks/2026-10-21-hermes-case9b-handoff.md

## Dispatch

- Run: run_702ee8c55062 | Task: task_76912f16db8b | Dispatch: ctx_56847c551fe2
- Agent: codex | Terminal: term_322b3f65-02db-41c6-a68d-12f66bf4d129 | Worktree reused (không tạo mới)
