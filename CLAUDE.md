# Claude instructions

Follow the repository-wide workflow in AGENTS.md.

Before starting implementation, create or update:

~~~text
docs/tasks/YYYY-MM-DD-<feature-key>.md
~~~

For a new feature, identify the affected repos, fetch the newest origin/develop or fallback origin/main, and create matching worktrees with the shared branch name feat/<feature-key>. Do not modify code before recording the worktree table in the task file.

Preserve existing local changes and untracked files. Never reset, force-checkout, delete, or remove worktrees without explicit approval. Update the task record with progress, validation, commits, MR links, blockers and next steps.
