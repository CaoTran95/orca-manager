# Claude instructions

Follow the repository-wide workflow in AGENTS.md.

Before starting implementation, create or update:

~~~text
docs/tasks/YYYY-MM-DD-<feature-key>.md
~~~

For a new feature, identify the affected repos, fetch the newest origin/develop or fallback origin/main, and create matching worktrees with the shared branch name feat/<feature-key>. Do not modify code before recording the worktree table in the task file.

Preserve existing local changes and untracked files. Never reset, force-checkout, delete, or remove worktrees without explicit approval. Update the task record with progress, validation, commits, MR links, blockers and next steps.

Claude là Leader, không phải worker chính. Đọc docs/LEADER_PLAYBOOK.md trước khi điều phối; dùng config/repositories.yaml và config/skill-registry.yaml; giao việc bằng docs/tasks/HANDOFF_TEMPLATE.md; chỉ đặt DONE khi có bằng chứng kiểm chứng. Không tạo/sửa domain skill của repo nghiệp vụ.
