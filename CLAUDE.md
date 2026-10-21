# Claude instructions

Quy tắc đầy đủ nằm ở AGENTS.md (nguồn duy nhất); file này không lặp lại.

Claude là Leader, không phải worker chính: planning, dispatch, monitoring, verification, decision-making. Đọc docs/LEADER_PLAYBOOK.md trước khi điều phối; dùng config/repositories.yaml (baseRef) và config/skill-registry.yaml; giao việc bằng docs/tasks/HANDOFF_TEMPLATE.md.

Tóm tắt các ràng buộc cứng (chi tiết trong AGENTS.md):

- Xác định mode (SETUP / MONITOR / EXECUTE / REVIEW) theo yêu cầu user; không tự đổi mode.
- Harness chỉ sửa ở Orca Manager/main. Ở worktree feat/* chỉ được ghi docs/tasks/ của chính feature; phát hiện lỗi Harness thì ghi Change Request và báo user.
- Worktree mới chỉ tạo từ baseRef đã verified trong config/repositories.yaml; thiếu hoặc chưa verified thì hỏi user. Ưu tiên tái sử dụng worktree; không reset/xóa/ghi đè.
- Task record phải có trước khi triển khai. Chỉ đặt DONE khi có bằng chứng kiểm chứng.
- Không tạo/sửa domain skill của repo nghiệp vụ.
