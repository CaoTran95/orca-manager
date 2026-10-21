# Orca Manager — Hướng dẫn quản lý project và worktree

## 1. Vị trí project

Project Orca Manager chính:

```text
/Users/android/orca/projects/Orca Manager
```

Mỗi task được quản lý bằng một task record trong:

~~~text
/Users/android/orca/projects/Orca Manager/docs/tasks/
~~~

Xem [docs/tasks/README.md](./tasks/README.md) và dùng [docs/tasks/TEMPLATE.md](./tasks/TEMPLATE.md) khi bắt đầu task mới.

Dashboard local theo dõi server/worktree được đặt riêng tại:

```text
/Users/android/Desktop/android/hermes/Orca Manager
```

Chạy dashboard:

```bash
cd "/Users/android/Desktop/android/hermes/Orca Manager"
npm start
```

Mở trình duyệt tại <http://127.0.0.1:4173>.

Dashboard đọc dữ liệu local từ `orca`, `lsof` và `ps`. Mặc định chỉ hiển thị application server đã map được với project/worktree; Serena, Chrome, agent-browser và các tool process được ẩn.

## 2. Kiểm tra Orca CLI

```bash
command -v orca
orca --help
orca status
```

Các lệnh hay dùng:

```bash
orca project list
orca repo list
orca worktree list
orca worktree ps
orca terminal list
```

Dùng JSON khi cần xử lý bằng script:

```bash
orca worktree list --json
orca worktree ps --json --limit 200
orca terminal list --json --limit 200
```

## 3. Project và repo

Liệt kê project bền vững mà Orca biết:

```bash
orca project list
```

Liệt kê checkout/repo đã đăng ký:

```bash
orca repo list
```

Thêm một checkout hiện có vào Orca:

```bash
orca repo add --path /absolute/path/to/repository
```

Ví dụ:

```bash
orca repo add --path /Users/android/Desktop/android/bidu-ecommerce-webapp
```

## 4. Cập nhật baseRef an toàn

`fetch` chỉ cập nhật remote-tracking ref, không ghi đè file local. `<branch>` là phần sau `origin/` của `baseRef` repo đó trong `config/repositories.yaml`:

```bash
git -C /absolute/path/to/repository fetch origin <branch>
git -C /absolute/path/to/repository log -1 --oneline origin/<branch>
```

Trước khi merge/rebase, kiểm tra thay đổi local:

```bash
git -C /absolute/path/to/repository status --short --branch
```

Không reset hoặc checkout cưỡng bức khi chưa xác nhận file local cần giữ.

## 5. Tạo worktree mới từ baseRef

```bash
orca worktree create \
  --repo path:/absolute/path/to/repository \
  --name feature-name \
  --base-branch <baseRef> \
  --no-parent \
  --setup inherit \
  --json
```

Ví dụ:

```bash
orca worktree create \
  --repo path:/Users/android/Desktop/android/bidu-ecommerce-webapp \
  --name feat/content-translation-ai \
  --base-branch <baseRef> \
  --no-parent \
  --setup inherit \
  --json
```

Orca có thể chuẩn hóa dấu `/` trong `--name` thành dấu `-`. Nếu branch phải chính xác có slash, kiểm tra và đổi tên branch sau khi tạo:

```bash
git -C /path/to/worktree branch -m old-name feat/content-translation-ai
orca worktree set \
  --worktree path:/path/to/worktree \
  --display-name feat/content-translation-ai \
  --json
```

Trước khi tạo, kiểm tra branch/worktree đã tồn tại chưa:

```bash
git -C /path/to/repository worktree list
git -C /path/to/repository branch --list 'feat/content-translation-ai'
```

Một branch không thể được checkout đồng thời ở hai worktree.

## 5A. Quy tắc AI khi mở tính năng mới

Khi người dùng yêu cầu mở một tính năng mới, AI phải tự động chuẩn bị worktree theo quy trình này.

### Quy tắc đặt tên

Tạo một `feature-key` dạng kebab-case, ngắn và ổn định:

```text
<feature-key> = content-translation-ai
branch       = feat/content-translation-ai
```

Nếu một tính năng chạy qua nhiều repo, dùng cùng một branch name trên tất cả repo:

```text
feat/content-translation-ai
```

Tên worktree/display name dùng chung quy tắc:

```text
<feature-key> · <repo-short-name>
```

Ví dụ:

```text
content-translation-ai · bidu-ecommerce-backend
content-translation-ai · bidu-ecommerce-webapp
content-translation-ai · bidu-hermes-agent
```

Orca thường lưu thư mục vật lý theo dạng:

```text
/Users/android/orca/workspaces/<repo-short-name>/<feature-key>
```

Không đưa tên cá nhân, timestamp hoặc tên máy vào branch/worktree name.

### Chọn repo liên quan

AI phải xác định repo nào thực sự cần thay đổi dựa trên yêu cầu và source hiện tại. Không tạo worktree cho toàn bộ project nếu tính năng chỉ liên quan một repo.

Các nhóm thường gặp:

- UI/web: `bidu-ecommerce-webapp`.
- Commerce API: `bidu-ecommerce-backend`.
- Community API: `bithumb-fashion-backend`.
- AI translation/service: `bidu-ai-backend`.
- MCP/agent: `bidu-mcp`, `bidu-hermes-agent` hoặc `Hermes Agentic`.
- Job nền: `bidu-commerce-cronjob-backend`.
- Admin: `bidu-admin`.

Nếu phạm vi repo không rõ hoặc có nhiều cách hiểu làm thay đổi kết quả, AI phải hỏi trước khi tạo worktree.

### Chọn base branch (baseRef)

Không mặc định `origin/develop` hay `origin/main`. Với từng repo liên quan, AI phải:

1. Đọc entry của repo trong `config/repositories.yaml`: `baseRef` và `status`.
2. `status` khác `verified` hoặc thiếu `baseRef` (vd. `needs-confirmation`): dừng, hỏi người dùng xác nhận baseRef, ghi quyết định vào task file trước khi tạo worktree.
3. Kiểm tra repo path, remote, branch, `git status` và worktree hiện có; ưu tiên tái sử dụng.
4. Fetch đúng branch của baseRef và xác minh ref tồn tại.
5. Không dùng local branch cũ thay cho remote-tracking ref.

```bash
git -C /path/to/repo fetch origin <branch>
git -C /path/to/repo show-ref --verify --quiet refs/remotes/origin/<branch>
```

### Tạo worktree tự động

Sau khi chọn base ref, AI tạo một worktree cho từng repo:

```bash
orca worktree create \
  --repo path:/path/to/repo \
  --name <feature-key> \
  --base-branch <baseRef> \
  --no-parent \
  --setup inherit \
  --json
```

Sau khi tạo, AI phải xác nhận:

```bash
git -C /path/to/worktree status --short --branch
git -C /path/to/worktree symbolic-ref --short HEAD
```

Nếu Orca biến `feat/<feature-key>` thành `feat-<feature-key>`, AI phải đổi branch Git về đúng `feat/<feature-key>` và cập nhật display name, không để hai repo dùng hai quy tắc tên khác nhau.

### Không ghi đè worktree có sẵn

Trước khi tạo, AI phải kiểm tra branch/worktree trùng tên. Nếu đã tồn tại:

- Nếu sạch và đúng base: dùng lại worktree đó.
- Nếu có thay đổi local, commit chưa push hoặc base khác: không reset, không xoá, báo trạng thái cho người dùng.
- Nếu branch đang checkout ở worktree khác: dùng worktree hiện có hoặc hỏi người dùng; không force checkout.

### Handoff sau khi tạo

Sau khi chuẩn bị xong, AI phải báo một bảng ngắn gồm:

| Repo | baseRef | Branch | Worktree | Trạng thái |
| --- | --- | --- | --- | --- |
| bidu-ecommerce-backend | <baseRef> | feat/<feature-key> | `/Users/android/orca/workspaces/...` | ready |

Chỉ sau khi tất cả worktree cần thiết ở trạng thái `ready`, AI mới bắt đầu sửa code. Nếu một repo bị thiếu remote, DNS, credential hoặc branch gốc, phải báo repo đó là `blocked` và không giả vờ đã tạo xong.

## 6. Theo dõi worktree và terminal

```bash
orca worktree list
orca worktree show --worktree path:/path/to/worktree
orca worktree current
orca worktree ps --json --limit 200
orca terminal list --worktree path:/path/to/worktree --json
```

Các thông tin cần chú ý:

- `branch`: branch Git thực tế.
- `path`: thư mục checkout.
- `workspaceStatus`: trạng thái trong Orca.
- `liveTerminalCount`: số terminal đang sống.
- `connected`: terminal còn kết nối hay không.
- `preview`: output gần nhất của terminal/agent.

## 7. Tổ chức worktree theo feature

Orca hiện quản lý native theo repo/worktree, chưa có feature group độc lập dùng chung cho nhiều repo. Có thể dùng:

- Prefix branch thống nhất, ví dụ `feat/case9-*`.
- Parent/child lineage với `--parent-worktree`.
- Comment và GitLab issue/MR trên worktree.
- Dashboard local để gom theo feature nếu cần.

Ví dụ naming:

```text
case9/ecommerce
case9/cronjob
case9/hermes
```

## 8. Kiểm tra local server

Liệt kê TCP listener trên macOS:

```bash
lsof -nP -iTCP -sTCP:LISTEN
```

Dashboard tự map server vào worktree dựa trên thư mục chạy (`cwd`). Nếu process chạy ngoài thư mục project, nó sẽ nằm ở nhóm system/chưa map hoặc bị ẩn theo bộ lọc mặc định.

## 9. Quy trình đề xuất

1. Tạo `feature-key` và xác định repo liên quan.
2. Kiểm tra `orca status`, repo và worktree hiện tại.
3. Kiểm tra `git status --short --branch` và branch trùng tên.
4. Đọc baseRef của từng repo trong `config/repositories.yaml` (chưa verified thì hỏi user) rồi fetch đúng branch đó.
5. Tạo worktree/branch theo cùng một quy tắc tên ở mọi repo liên quan.
6. Xác nhận path, branch và trạng thái `ready`.
7. Chạy setup/test trong đúng worktree.
8. Dùng `orca worktree ps` và dashboard để theo dõi process.
9. Trước khi push, kiểm tra diff, test và file untracked.

## 10. Lưu ý an toàn

- Không dùng `git reset --hard` hoặc `git worktree remove` nếu chưa xác nhận dữ liệu cần giữ.
- Không đưa `.env`, token, service account hoặc credential vào commit.
- File `.serena/` và `node_modules/` thường là untracked local state; kiểm tra trước khi xoá.
- `orca repo add` đăng ký repo vào Orca nhưng không tự push code.

## 11. Ghi chép bắt buộc cho mỗi task

Mỗi task mới phải có một file:

~~~text
docs/tasks/YYYY-MM-DD-<feature-key>.md
~~~

AI phải tạo/cập nhật file này trong suốt vòng đời task. Tối thiểu phải ghi:

- Yêu cầu và phạm vi.
- Repo, base ref, branch và path của từng worktree.
- Tiến độ theo từng mốc.
- Commit, push/MR và validation.
- File untracked/local changes.
- Blocker, quyết định và bước tiếp theo.

Task chỉ được đánh dấu completed khi phần code cần thiết và validation đã hoàn tất; nếu thiếu quyền, credential, DNS, test data hoặc trạng thái remote thì ghi blocked kèm bằng chứng.
