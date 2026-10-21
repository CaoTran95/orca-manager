# Orca Manager agent instructions

Áp dụng cho Claude, Codex, Cursor và mọi agent làm việc từ project này. `CLAUDE.md` chỉ trỏ về đây; không lặp lại quy tắc ở nơi khác.

Nguồn sự thật: `config/repositories.yaml` (repo + `baseRef`), `config/skill-registry.yaml` (mục lục skill), `docs/LEADER_PLAYBOOK.md` (điều phối), `docs/tasks/` (trạng thái task), `docs/ORCA_MANAGER_GUIDE.md` (lệnh Orca chi tiết).

## 1. Harness ownership & isolation

Harness = `CLAUDE.md`, `AGENTS.md`, `.cursor/`, `.claude/skills/`, `config/`, `scripts/`, `docs/LEADER_PLAYBOOK.md`, `docs/ORCA_MANAGER_GUIDE.md`, `docs/tasks/{README,TEMPLATE,HANDOFF_TEMPLATE}.md`, management skills.

- Chỉ worktree `main` của Orca Manager được sửa Harness.
- Worktree `feat/*` của Orca Manager chỉ được tạo/sửa task record được phân quyền (guard kiểm tra, không chỉ dựa vào tên file):
  1. `docs/tasks/YYYY-MM-DD-<feature-key>[-suffix].md` (khớp `feat/<feature-key>`; `/` trong tên branch -> `-`);
  2. feature lớn nhiều task con: file MỚI khai báo trong front matter `owns:` (danh sách path docs/tasks/, không glob) của file chính `YYYY-MM-DD-<feature-key>.md`;
  3. file docs/tasks/ ĐÃ có trong main hoặc quyền chéo: chỉ khi main duyệt trong `config/task-ownership.yaml` (mỗi task một `owner` chính; `grandfathered` chỉ để giữ quyền đã có; `owner_status: proposed` = chờ user xác nhận).
  Hai feature không được cùng claim một task: `owns:` trùng nhau, trùng owner của registry, hoặc lấn file chính của feature có key dài hơn (`a` vs `a-b`) đều bị guard từ chối (`scripts/ownership.rb conflicts`).
  Không bao giờ ghi được README/TEMPLATE/HANDOFF_TEMPLATE, symlink, hay file ngoài docs/tasks/.
- Ở `feat/*` cấm: sửa Harness; tạo/sửa/xóa management skill; đổi config; đổi script/quy trình; tự sync/cherry-pick/rebase/merge từ main; giao worker sửa Harness; tự chuyển sang main để né quy tắc.
- Phát hiện Harness lỗi: ghi Change Request (đề xuất + bằng chứng) vào task file của feature, báo user, chờ xử lý tại main.
- Không tự chuyển branch/đồng bộ khi có thay đổi chưa commit. Nâng cấp Harness chỉ khi user yêu cầu rõ.
- Guard (không chỉ dựa vào văn bản): `scripts/guard-harness.sh` kiểm tra working tree, file staged và commit của branch (so với main); nội dung trùng khít main (đồng bộ do user duyệt) không bị coi là sai lệch. Chạy tự động qua hook `pre-commit` và `pre-merge-commit`, được cài bằng `scripts/install-hooks.sh` (tại main) vào `<git-common-dir>/hooks` dùng chung mọi worktree, tự tìm main lúc chạy nên không phụ thuộc path và không dùng `core.hooksPath` (path tuyệt đối sẽ im lặng mất hiệu lực khi di chuyển repo). Hook không chặn được bypass cố ý, nên Leader chạy `scripts/guard-harness.sh` ở bước Verify; `scripts/harness-status.sh` liệt kê hook/guard/độ lệch Harness của mọi worktree; `scripts/test-guard.sh` là bộ kiểm thử guard.
- Instruction nạp theo cwd (đã kiểm chứng bằng probe 2026-10-21): Claude chỉ nạp CLAUDE.md của worktree (AGENTS.md chỉ được tham chiếu, chưa nạp) cộng `~/.claude` và memory index của project Orca Manager (dùng chung mọi worktree); Codex nạp AGENTS.md của worktree; Cursor nạp `.cursor/rules`, CLAUDE.md và AGENTS.md của worktree. Không agent nào tự đọc Harness ở main: Harness mới chỉ có hiệu lực khi các file đó TRONG worktree là bản mới. Kiểm tra bằng `scripts/harness-status.sh`; đường dẫn tồn tại không có nghĩa là đã áp dụng.
- Trước mọi thao tác ghi, kiểm tra git worktree và đường dẫn đích; file Harness ở feature worktree => từ chối và báo cáo.
### Worker Isolation (Codex/Cursor không chỉnh sửa main)

- Worker (Codex/Cursor) KHÔNG BAO GIỜ ghi trực tiếp vào checkout main của Orca Manager hay checkout chính của repo nghiệp vụ; chỉ làm trong linked worktree được giao. Leader chạy `scripts/guard-dispatch.sh <worktree> [--kind business|harness]` trước mỗi lần dispatch; bị từ chối thì không giao.
- Cần worker soạn thay đổi Harness: user duyệt một branch `harness/<topic>` trong `harness_staging` (`config/task-ownership.yaml`, sửa ở main) -> tạo worktree riêng -> giao với `--kind harness` -> Leader review diff -> `scripts/integrate-harness.sh harness/<topic>` tại main (kiểm tra check-config + test-guard trong staging trước, fast-forward, xác nhận bằng tên branch). Main đã tiến thì rebase staging bằng `scripts/sync-harness.sh --apply` trước.
- Phát hiện: hook `commit-msg` chặn commit trên main mang trailer `Co-authored-by` của Codex/Cursor; `check-config.sh` cảnh báo khi main có thay đổi chưa commit. Giới hạn đã kiểm chứng: Codex/Cursor không đặt biến môi trường nhận diện nên không chặn được theo danh tính; dựa vào dispatch preflight + phát hiện sau.

## Đồng bộ Harness vào feature worktree (rebase)

Mặc định là REBASE lên main, không merge: `scripts/sync-harness.sh --check [--worktree PATH]` (read-only, mô phỏng replay từng commit) rồi `scripts/sync-harness.sh --apply --worktree PATH` tại main, chỉ khi user yêu cầu. Từ chối nếu có thay đổi local, merge commit, commit đã push, đang rebase/merge dở, hoặc replay conflict; có xác nhận bằng tên branch; sao lưu `refs/orca-sync-backup/...`; không stash/reset/force-push, không tự giải conflict (conflict thì abort về nguyên trạng).

## 2. Execution modes

| Mode | Được làm | Không được làm |
| --- | --- | --- |
| SETUP | Sửa Harness, chỉ trên `main` | Sửa repo nghiệp vụ, dispatch worker code |
| MONITOR | Chỉ đọc trạng thái (`scripts/agent-monitor.sh`, `orca ... list`) | Ghi, giao việc |
| EXECUTE | Giao task nghiệp vụ theo yêu cầu user | Sửa Harness |
| REVIEW | Kiểm chứng kết quả, báo cáo | Triển khai feature khác |

Không tự đổi mode: SETUP/MONITOR không tự chuyển sang EXECUTE, và không tiếp tục task nghiệp vụ cũ khi user chưa yêu cầu.

## 3. Repository / worktree workflow

Trước khi triển khai feature mới:

1. Tạo/cập nhật `docs/tasks/YYYY-MM-DD-<feature-key>.md` (từ `docs/tasks/TEMPLATE.md`).
2. Chỉ chọn repo thực sự bị ảnh hưởng. Mỗi feature có thể gắn nhiều repo và nhiều worktree.
3. Với mỗi repo, đọc entry trong `config/repositories.yaml`. **Không mặc định `origin/develop` hay `origin/main`**: chỉ dùng `baseRef` của repo đó.
   - Thiếu `baseRef` hoặc `status` khác `verified` (vd. `needs-confirmation`): dừng, hỏi user xác nhận baseRef trước khi tạo worktree; ghi quyết định vào task file.
4. Kiểm tra repo, remote, branch, path, `git status --short --branch` và danh sách worktree hiện có (`orca worktree list --json`, `git worktree list`).
5. Ưu tiên tái sử dụng worktree đã có cho `feat/<feature-key>`. Chỉ tạo mới khi chưa có: `git fetch origin <branch của baseRef>`, rồi `orca worktree create --repo <selector> --name <feature-key> --base-branch <baseRef> --no-parent --setup inherit --json`.
6. Cùng một branch `feat/<feature-key>` ở mọi repo liên quan; display name `<feature-key> · <repo-short-name>`; không chứa username/timestamp/máy.
7. Xác minh path và branch của từng worktree, ghi bảng (repo, baseRef, branch, path, status) vào task file **trước khi** giao code.

## 4. Safety

- Không reset, force-checkout, xóa/remove worktree hoặc ghi đè thay đổi chưa commit, file untracked, commit, worktree có sẵn khi chưa có approval rõ.
- Branch đã checkout ở worktree khác: dùng lại worktree đó hoặc báo xung đột.
- Không tạo worktree cho repo không liên quan.
- Không commit `.env`, token, credential, service-account, `.serena/`, `node_modules/`.
- Thay đổi code nằm ở worktree repo nghiệp vụ; task record và ghi chú điều phối nằm ở project này.

## 5. Leader / Worker

Claude Leader chỉ làm: planning, dispatch, monitoring, verification, decision-making.

Codex/Cursor Worker làm: phân tích source chuyên sâu, implementation, debugging, testing, technical review, Git operations phức tạp (tách commit, cherry-pick, rebase) được giao. Không gán cố định agent theo loại repo; chọn theo độ phức tạp, phiên đang sống, chi phí.

- Delegate-first, nhưng Leader tự làm nhanh các thao tác quản trị nhỏ bằng CLI (đọc trạng thái, git status, cập nhật task file, tạo worktree).
- EXECUTE: phải dispatch thật qua Orca CLI và xác minh worker ID, session/terminal ID, repo, worktree và task tương ứng (không chỉ viết handoff). Dispatch lỗi => báo lỗi cho user; Leader không tự chuyển sang coding.
- Handoff theo `docs/tasks/HANDOFF_TEMPLATE.md`: acceptance criteria, repo, worktree, baseRef, skills, phạm vi, test bắt buộc.
- Domain skill: chỉ dùng skill có thật, tra qua `config/skill-registry.yaml`, xác minh path/nội dung tại đúng worktree, truyền path cho worker; không nạp cả skill vào context Leader; không tạo/sửa/sao chép skill khi chưa được duyệt.
- Vòng đời: Plan → Dispatch → Monitor → Verify → Correct → Approve. Tối đa 2 vòng sửa. Không đặt DONE chỉ dựa trên báo cáo worker. Chi tiết: `docs/LEADER_PLAYBOOK.md`.

## 6. Task record

Cập nhật tại mỗi mốc: yêu cầu/phạm vi; bảng repo/baseRef/branch/worktree; tiến độ; lệnh + kết quả validation; commit/push/MR; thay đổi local/untracked; blocker và bước tiếp.
Trạng thái task: `TODO → READY → IN_PROGRESS → REVIEW → DONE`, ngoại lệ `BLOCKED`, `FAILED`, `WAITING_APPROVAL` (file cũ dùng planned/in-progress/completed/blocked/paused vẫn được chấp nhận). Không tuyên bố hoàn thành khi thiếu bằng chứng.

## 7. Lệnh hữu ích

~~~bash
orca repo list
orca worktree list
orca worktree ps --json --limit 200
orca terminal list --json --limit 200
git -C /path/to/repo status --short --branch
scripts/check-config.sh          # YAML, repo, skill path, policy, guard
scripts/guard-harness.sh         # kiểm tra thay đổi Harness trái phép
scripts/harness-status.sh        # hook/guard/độ lệch Harness của từng worktree (read-only)
scripts/test-guard.sh            # kiểm thử guard trên clone tạm
scripts/ownership.rb conflicts   # xung đột claim task record giữa các feature
~~~
