# Orca Manager agent instructions

These instructions apply to Codex and any agent working from this project.

## Mandatory task workflow

Before implementing a new feature:

1. Create or update one task record in docs/tasks/YYYY-MM-DD-<feature-key>.md.
2. Identify only the repositories that are actually affected.
3. Inspect each repo's current worktrees, branch, remote and local changes.
4. Fetch the latest base branch for each affected repo:
   - prefer origin/develop;
   - fall back to origin/main when origin/develop does not exist.
5. Create one worktree per affected repo from that remote base.
6. Use the same branch name in every affected repo: feat/<feature-key>.
7. Verify every worktree path and branch before editing code.

Do not start implementation until the task record contains the affected repos, base refs, branch names, worktree paths and their statuses.

## Naming

Use a short kebab-case feature key:

~~~text
feature-key: content-translation-ai
branch:      feat/content-translation-ai
~~~

Use the same feature key across repos so the work can be found together. Use the worktree display convention:

~~~text
<feature-key> · <repo-short-name>
~~~

Do not include usernames, timestamps or machine names in branch/worktree names.

## Safety

- Never reset, force-checkout, delete or remove a worktree without explicit user approval.
- Never overwrite local changes, untracked files, commits or an existing worktree.
- If the requested branch is already checked out elsewhere, reuse that worktree or report the conflict.
- Do not create worktrees for unrelated repositories.
- Do not commit .env, tokens, credentials, service-account files, .serena/ or node_modules/.
- Keep implementation changes in the target repo worktrees; keep task records and orchestration notes in this project.

## Required task record updates

Update the task file at every meaningful milestone:

- request and scope;
- repo/base/branch/worktree table;
- implementation progress;
- commands and validation results;
- commits, push and MR links;
- untracked/local changes;
- blockers and next steps.

Use statuses planned, in-progress, completed, blocked or paused. Do not claim completion without validation evidence.

## Useful commands

~~~bash
orca project list
orca repo list
orca worktree list
orca worktree ps --json --limit 200
orca terminal list --json --limit 200
git -C /path/to/repo status --short --branch
git -C /path/to/repo fetch origin develop
~~~

Read the detailed workflow before a multi-repo task:

- docs/ORCA_MANAGER_GUIDE.md
- docs/tasks/README.md
- docs/tasks/TEMPLATE.md
