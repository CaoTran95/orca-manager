# Orca Manager

Harness điều phối nhiều repo và worktree trên Orca cho Claude (Leader) cùng Codex/Cursor (Worker). Không có server, DB hay web app; chỉ gồm tài liệu, cấu hình và script shell/Python.

Quy tắc ràng buộc nằm ở [`AGENTS.md`](AGENTS.md) (nguồn duy nhất); README này chỉ giới thiệu và chỉ đường.

## Cách hoạt động

- **Leader (Claude)** lập kế hoạch, giao việc, theo dõi, kiểm chứng, quyết định.
- **Worker (Codex/Cursor)** làm việc trong linked worktree `feat/<feature-key>`. Worker mới ưu tiên Cursor, nhiều worker thì xen kẽ Cursor/Codex.
- Mỗi tính năng có một **task record** trong `docs/tasks/`, tạo trước khi triển khai. Chỉ đặt `DONE` khi có bằng chứng kiểm chứng.
- **Harness chỉ sửa ở `main`.** Ở `feat/*` chỉ được ghi `docs/tasks/` của chính tính năng đó.
- Worktree mới chỉ tạo từ `baseRef` đã `verified` trong `config/repositories.yaml`.

## Cấu trúc

| Đường dẫn | Nội dung |
|---|---|
| `AGENTS.md` | Quy tắc cho mọi agent (Claude, Codex, Cursor) |
| `CLAUDE.md`, `.cursor/rules/` | Trỏ về `AGENTS.md` cho từng agent |
| `config/repositories.yaml` | Danh mục repo: `baseRef`, `status`, remote |
| `config/skill-registry.yaml` | Domain skill theo repo và loại task |
| `config/task-ownership.yaml` | Quyền sở hữu task, branch `harness/*` staging |
| `docs/LEADER_PLAYBOOK.md` | Cách Leader vận hành từng bước |
| `docs/ORCA_MANAGER_GUIDE.md` | Hướng dẫn Orca CLI, baseRef, worktree |
| `docs/tasks/` | Task record, `TEMPLATE.md`, `HANDOFF_TEMPLATE.md` |
| `scripts/` | Công cụ vận hành (bảng dưới) |

## Script chính

| Script | Việc |
|---|---|
| `scripts/new-task.sh <key> --repo <id> [--apply]` | Lập kế hoạch rồi tạo task record + worktree; không dispatch worker |
| `scripts/agent-monitor.sh` | Dashboard agent chỉ đọc (`--once`, `--watch 5`, `--json`, `--html FILE`) |
| `scripts/orca-status.sh [key]` | Tóm tắt worktree và terminal |
| `scripts/check-config.sh` | Kiểm tra YAML, baseRef, skill path |
| `scripts/guard-dispatch.sh <worktree>` | Preflight trước khi giao việc cho worker |
| `scripts/harness-status.sh` | Mỗi worktree đang dùng Harness bản nào so với `main` |
| `scripts/sync-harness.sh --check\|--apply` | Đồng bộ Harness từ `main` sang worktree bằng rebase |
| `scripts/integrate-harness.sh harness/<topic>` | Đưa thay đổi Harness do worker soạn vào `main` (fast-forward) |
| `scripts/install-hooks.sh` | Cài guard hook dùng chung của repo |
| `scripts/test-*.sh` | Kiểm thử guard, new-task, sync trên repo tạm |

## Bắt đầu

Yêu cầu: Orca với CLI `orca`, `git`, `ruby`, `python3` (monitor tương tác cần `python3.11 -m pip install -r scripts/requirements-agent-monitor.txt`).

```bash
scripts/install-hooks.sh                      # một lần
scripts/check-config.sh                       # kiểm tra cấu hình
scripts/new-task.sh my-feature --repo <id>    # xem kế hoạch; thêm --apply để tạo
scripts/agent-monitor.sh --once               # xem agent đang chạy
```

Bốn chế độ làm việc (SETUP / MONITOR / EXECUTE / REVIEW) và ràng buộc chi tiết: xem `AGENTS.md`, rồi `docs/LEADER_PLAYBOOK.md`.
