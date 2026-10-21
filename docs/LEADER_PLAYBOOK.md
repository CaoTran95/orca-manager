# Orca Manager V1 — Leader playbook

Quy tắc ràng buộc nằm ở `AGENTS.md` (nguồn duy nhất); playbook này mô tả cách vận hành. Không xây thêm server/DB/dashboard.

## Vai trò và mode

- **Claude Leader**: planning, dispatch, monitoring, verification, decision-making. Delegate-first; tự làm nhanh các thao tác quản trị nhỏ bằng CLI (đọc trạng thái, `git status`, cập nhật task file, tạo/tái sử dụng worktree).
- **Codex/Cursor Worker**: phân tích source chuyên sâu, implementation, debugging, testing, technical review, Git phức tạp được giao. Không gán cứng agent theo loại repo.
- **Mode** (user quyết định, không tự đổi): SETUP (sửa Harness, chỉ ở `main`), MONITOR (chỉ đọc), EXECUTE (giao task nghiệp vụ), REVIEW (kiểm chứng, không triển khai feature khác).
- **Harness ownership**: Harness chỉ sửa ở Orca Manager/main. Ở `feat/*` chỉ ghi `docs/tasks/` của chính feature; lỗi Harness => ghi Change Request vào task file, báo user, chờ main xử lý. Guard: `scripts/guard-harness.sh`.

## Nguồn sự thật

| Cần biết | Xem ở |
| --- | --- |
| Repo, base branch | `config/repositories.yaml` |
| Skill nào ở repo nào | `config/skill-registry.yaml` (chỉ là mục lục) |
| Trạng thái feature/task | `docs/tasks/YYYY-MM-DD-<feature-key>.md` |
| Worktree/terminal/agent thực tế | `orca worktree list/ps --json`, `orca terminal list --json` |
| Agent gần thời gian thực | `scripts/agent-monitor.sh --once` hoặc `--watch 5` |
| Cách dùng orchestration | `orca skills get orchestration`, `orca skills get orca-cli` |

Skill vận hành dùng bản chính thức của Orca (`orchestration`, `orca-cli`); không tạo skill quản trị trùng lặp. Domain skill thuộc repo nghiệp vụ: không tạo/sửa/sao chép.

## Quy trình một feature

1. **Intake**: ghi yêu cầu, acceptance criteria, repo bị ảnh hưởng vào task file (từ TEMPLATE.md). Chia task theo repo, đánh dấu dependency và task chạy song song.
2. **Chuẩn bị worktree** (theo AGENTS.md mục 3): đọc `baseRef` + `status` của từng repo trong `config/repositories.yaml` (không mặc định develop/main; thiếu hoặc chưa `verified` => hỏi user trước). Kiểm tra repo, remote, branch, path, `git status`, `orca worktree list --json`; ưu tiên tái sử dụng worktree của `feat/<feature-key>`; chỉ tạo mới khi chưa có: `git fetch origin <branch của baseRef>` rồi
   `orca worktree create --repo <selector> --name <feature-key> --base-branch <baseRef> --no-parent --setup inherit --json`
   Ghi repo/baseRef/branch/path/status vào bảng worktree **trước khi** giao code.
3. **Chọn worker**: theo độ phức tạp, agent đang sẵn sàng/phiên có thể tiếp tục (`orca terminal list --json`), chi phí. Không gán cứng agent theo công nghệ. Một worktree chỉ một worker ghi tại một thời điểm.
4. **Tra skill**: lấy skill từ registry theo repo + loại task, kiểm tra file tồn tại trong worktree được giao (`test -f "<worktree>/<path>"`), ghi path vào handoff. Chỉ truyền path, không đọc nội dung vào context Leader. Chưa xác minh Codex/Cursor tự nhận skill giống nhau nên luôn truyền path tường minh.
5. **Giao việc** bằng `docs/tasks/HANDOFF_TEMPLATE.md`:
   - Giao có giám sát: `orca orchestration run-create --objective "<feature>" --json`, rồi `orca orchestration worker-start --spec "<handoff>" --worktree path:<path> --agent <codex|cursor|claude> --json`; chờ bằng `orca orchestration check --wait --types worker_done,escalation,question --json`.
   - Giao đơn giản/không giám sát: dùng `orca-cli` (terminal tới phiên có sẵn bằng `orca terminal send`).
   Không khởi chạy trùng: kiểm tra `orca worktree ps --json` và `orca orchestration worker-list` trước.
   **Xác minh dispatch thật** (chỉ ở EXECUTE): sau khi giao, đối chiếu `orca orchestration worker-list` / `orca terminal list --json` để có worker ID, session/terminal ID, repo, worktree và task khớp với task table; ghi vào task file. Dispatch lỗi => báo lỗi cho user kèm output; Leader không tự chuyển sang coding.
6. **Theo dõi theo checkpoint** (không đọc log liên tục): khi có `worker_done`/escalation, hoặc khi người dùng yêu cầu. Trạng thái agent lấy bằng `scripts/agent-monitor.sh` (một lần hoặc `--watch 5`), không đọc log và không gọi AI cho mỗi lần refresh. Đọc kết quả giới hạn: `orca orchestration worker-read` / `orca terminal read` với giới hạn nhỏ. Timeout/empty không phải thất bại; không stop/retry khi chưa có bằng chứng tiến trình đã thoát.
7. **Verify**: xem bên dưới. Chưa đạt -> gửi chỉnh sửa cụ thể (`orchestration send`/`terminal send`) thay vì tự sửa.
8. **Approve & báo cáo**: cập nhật task file, tổng hợp tiến độ/test/blocker/quyết định cần người dùng duyệt.

## Delegate → Verify → Correct → Approve

Chỉ đặt DONE khi đủ bằng chứng theo acceptance criteria. Lời báo "xong" của worker không đủ.

Kiểm tra tối thiểu, ưu tiên rẻ trước:
- `git -C <worktree> status --short --branch` và `git diff --stat <base>...HEAD` (đúng repo/branch, đúng phạm vi).
- Chạy lại lệnh test/build chính trong handoff (tự chạy hoặc yêu cầu output thật); ghi lệnh + kết quả.
- Đọc diff chọn lọc ở file rủi ro cao (contract/API, migration, security), không đọc toàn bộ source.
- Tương thích API/dependency giữa các repo trước khi chuyển REVIEW -> DONE.
- Có runtime verification khi acceptance yêu cầu.

Đi sai hướng: gửi hướng dẫn ngắn nêu điều sai + tiêu chí đúng. Thay đổi kiến trúc hoặc contract -> WAITING_APPROVAL và hỏi người dùng.

## Trạng thái

`TODO → READY → IN_PROGRESS → REVIEW → DONE`; ngoại lệ: `BLOCKED`, `FAILED`, `WAITING_APPROVAL`.
(Task file cũ dùng planned/in-progress/completed/blocked/paused; V1 chấp nhận cả hai, ưu tiên bộ mới ở mục task bên trong file.)

## Khởi động lại / resume

1. Đọc task file của feature (`docs/tasks/`), bảng worktree và task table.
2. Đối chiếu thực tế: `scripts/agent-monitor.sh --once`, hoặc trực tiếp `orca worktree list --json` (path/branch còn tồn tại?), `git status` từng worktree, `orca terminal list --json` / `orca orchestration worker-list` (worker còn sống? session id).
3. Chỉ phân tích lại phần lệch trạng thái; ghi chênh lệch vào task file rồi tiếp tục.

## Theo dõi agent trong Terminal

`scripts/agent-monitor.sh` chỉ đọc. Không tạo/dừng agent, không sửa worktree và không đổi task.

```bash
scripts/agent-monitor.sh --once
scripts/agent-monitor.sh --watch 5
```

Mỗi snapshot gộp `orca orchestration run-list` và `worker-list` (mọi Run, theo `nextCursor`), `task-list --run`, `orca terminal list`, `orca worktree ps` / `worktree list`, và liên kết tường minh trong `docs/tasks/`. Cột `Origin`: `orchestration` khi session có trong worker-list; `manual` khi agent được mở ngoài record đó. `Task`, `Activity` và `Updated` chỉ điền khi nguồn ghi rõ; ô thiếu là `-`. Nhiều pane cùng loại trong một worktree không được ghép vào một terminal nếu không có khóa chung. Trang bị cắt, host không phủ, hoặc lệnh lỗi được in ở `# warnings` thay vì suy ra là không có agent.

## Giới hạn Leader

Hạn chế implement nghiệp vụ, debug lỗi đơn giản, đọc toàn bộ source, tải log lớn. Giao worker; chỉ kéo bằng chứng ngắn. Không tự reset, force push, xóa worktree, merge vào branch bảo vệ, hay chỉnh checkout chính của repo nghiệp vụ.

## Retry, escalation và phê duyệt

- Tối đa **2 vòng sửa** cho mỗi task: mỗi vòng nêu phần không đạt + tiêu chí đúng + phạm vi được sửa. Sau vòng 2 vẫn lỗi -> `FAILED`/`BLOCKED`, escalate cho người dùng kèm bằng chứng.
- Phần phức tạp (security, migration, contract liên repo) giao reviewer độc lập (worker/agent khác với người implement) và chỉ nhận báo cáo ngắn.
- Cần người dùng duyệt (`WAITING_APPROVAL`) trước: merge/push, baseRef chưa verified, thay đổi kiến trúc hay API contract, xóa/reset worktree, tạo worktree mới ở repo `needs-confirmation`, bổ sung domain skill. Leader không tự push hay merge.

## Tối ưu token

- Thu thập trạng thái bằng script/CLI, không dùng AI: `scripts/agent-monitor.sh --once`, `scripts/orca-status.sh [feature-key]`, `scripts/check-config.sh`, `git status/diff --stat`.
- Chỉ đọc phần cần cho quyết định hiện tại; worker đọc source và skill. Báo cáo worker <= 15 dòng; log dài lưu file và truyền path.
- Tiếp tục phiên worker đang sống (`orca terminal list`) thay vì khởi động lại; không phân tích lại feature khi task file còn hợp lệ.
- Không bỏ test/review để tiết kiệm token.

## Kiểm tra cấu hình

`scripts/check-config.sh` (read-only): YAML hợp lệ, trường baseRef/status của từng repo, mọi repo resolve qua Orca, mọi skill path tồn tại, không còn rule lỗi thời (mặc định develop/main), hooks guard đã bật. Chạy sau khi sửa Harness.
`scripts/guard-harness.sh` (read-only): ở feature worktree báo file Harness bị sửa trái phép (working tree + commit so với main); chạy tự động qua `.githooks/pre-commit`. Hook không chặn được `--no-verify`, nên Leader chạy guard ở bước Verify.

## Đồng bộ Harness sang feature worktree

Chỉ khi user yêu cầu và worktree sạch (`git status` không có thay đổi). Feature worktree không tự sync. Việc đồng bộ do user hoặc phiên SETUP thực hiện; nếu worktree đã có commit, ưu tiên không rebase/merge mà dùng Harness từ main đọc trực tiếp (đường dẫn tuyệt đối của main).

## Roadmap (chưa triển khai)

- V2: đồng bộ Base.vn MCP; quét/cập nhật registry định kỳ; Orca Automations theo lịch.
- V3: điều phối theo sự kiện/giám sát liên tục; dashboard riêng nếu Orca chưa đủ.

## Bài học từ lần dispatch thực tế (Hermes T2, 2026-10-21)

- **Follow-up sau `worker_done`**: worker đã settle không nhận thêm qua `orchestration send`. Gửi vòng sửa vào terminal worker đang sống: `orca terminal send --terminal <handle> --enter --text "<yêu cầu sửa cụ thể>"`, chờ `orca terminal wait --terminal <handle> --for tui-idle`, rồi đọc kết quả giới hạn bằng `orca terminal read --terminal <handle> --limit 40`. Ack delivery cũ bằng `orchestration check --ack <delivery_id>`. Tính vào giới hạn 2 vòng sửa; ghi vòng vào task file.
- **Worktree thiếu môi trường chạy test** (ví dụ `.venv`): không cài/tạo venv trong repo và không để worker tự cài. Tìm môi trường sẵn có của cùng repo (`ls -d <workspaces>/<repo>/*/.venv`), chỉ cho worker dùng để chạy (không sửa), nêu rõ đường dẫn trong yêu cầu sửa. Không có môi trường phù hợp -> `BLOCKED`, ghi lý do, hỏi người dùng; không báo test pass khi chưa chạy.
