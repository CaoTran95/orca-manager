# Task records

Mỗi task làm qua Orca phải có một file ghi chép trong thư mục này. Đây là nơi lưu tiến độ và quyết định của task, không lưu token, mật khẩu, .env hoặc credential.

## Quy tắc đặt tên

~~~text
YYYY-MM-DD-<feature-key>.md
~~~

Ví dụ:

~~~text
2026-10-20-case9-expanded.md
2026-10-20-content-translation-ai.md
~~~

Nếu cùng một feature có nhiều giai đoạn, giữ một file task và thêm section cập nhật theo thời gian; không tạo nhiều file trùng tên.

## Quy trình AI

Khi bắt đầu task:

1. Tạo file từ [TEMPLATE.md](./TEMPLATE.md).
2. Ghi yêu cầu, feature-key, repo liên quan và base ref.
3. Tạo worktree theo quy tắc trong [ORCA_MANAGER_GUIDE.md](../ORCA_MANAGER_GUIDE.md).
4. Ghi path, branch và trạng thái từng worktree.

Trong khi làm:

- Cập nhật mục Progress sau mỗi mốc quan trọng.
- Ghi rõ repo/worktree nào đã thay đổi.
- Ghi command kiểm tra và kết quả test/build.
- Ghi blocker ngay khi gặp; không đánh dấu hoàn thành nếu chưa kiểm chứng.

Khi kết thúc:

- Ghi commit, push/MR nếu có.
- Ghi file còn untracked hoặc thay đổi local chưa xử lý.
- Ghi việc còn lại và bước tiếp theo.
- Đặt trạng thái cuối là planned, in-progress, completed, blocked hoặc paused.

## Theo dõi task

Liệt kê task:

~~~bash
find docs/tasks -maxdepth 1 -type f -name '*.md' -print | sort
~~~

Tìm task theo feature:

~~~bash
rg -n -i 'case9|translation|blocked|in-progress' docs/tasks
~~~
