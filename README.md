# Task Manager for Neovim

A multi-repository task management system for Neovim that integrates Jira workflows with git worktrees and session management.

## Overview

This task manager helps you organize your work when a single Jira ticket requires changes across multiple repositories. It creates isolated workspaces for each task using git worktrees.

## How It Works

### Directory Structure

```
~/
├── repos/                    # Bare git repositories
│   ├── repo1/               # Bare repo (git clone --bare)
│   ├── repo2/               # Bare repo
│   └── repo3/               # Bare repo
└── tasks/                   # Task workspaces
    ├── dev-123/             # Task directory (one per Jira issue)
    │   ├── repo1/           # Git worktree for repo1
    │   └── repo2/           # Git worktree for repo2
    └── dev-456/
        └── repo3/
```

Each task directory is a separate Claude Code session, allowing you to maintain context per Jira ticket.

## Features

- **Multi-repo support**: Work on multiple repositories for a single Jira ticket
- **Git worktrees**: Isolated branches per task without switching in your main repos
- **Automatic session management**: Sessions restore automatically when you cd into a task
- **Jira issue picker**: Fuzzy-select any open Jira issue assigned to you (with manual entry fallback)
- **Interactive prompts**: Consistent Snacks.nvim inputs throughout the workflow
- **Telescope integration**: Quick navigation between tasks and repositories
- **Unified picker**: Manage existing tasks, create new ones, or clean stale worktrees from the Telescope UI (press <C-d> on a task entry to delete it).
- **Worktree cleanup tools**: Commands to prune stale git worktrees and remove task directories safely.
- **Contextual hooks**: Auto-open whatever tooling you like (CodeCompanion, Neotree, etc.) when you jump into a task workspace via configurable callbacks.

## Setup

### Install with Lazy.nvim

Add this spec to your Lazy config. While the repository is still local, point `dir` at this folder; once you publish it, drop the `dir` line and keep the GitHub slug.

```lua
{
  "bartcortooms/task-manager.nvim",
  dir = "~/dotfiles/task-manager", -- remove after pushing the repo
  dependencies = {
    "folke/snacks.nvim",
    "janBorowy/jirac.nvim",
    "grapp-dev/nui-components.nvim",
    "MunifTanjim/nui.nvim",
    "nvim-telescope/telescope.nvim",
  },
  config = function()
    require("task-manager").setup({
      jira_prefix = "DEV",
      jira = {
        url = "https://company.atlassian.net",
        email = "you@company.com",
        api_token = function()
          return vim.fn.system("security find-generic-password -s 'Jira API Token' -w")
        end,
      },
    })
  end,
}
```

### Dependencies

- `folke/snacks.nvim` (inputs, pickers)
- `janBorowy/jirac.nvim` + `nvim-lua/plenary.nvim` (Jira REST client)
- `grapp-dev/nui-components.nvim` + `MunifTanjim/nui.nvim` (menus)
- `nvim-telescope/telescope.nvim` (task picker)
- Optional integrations: `nvim-neo-tree/neo-tree.nvim`, `rmagatti/auto-session`

### 1. Create Bare Repositories

Convert your existing repos to bare clones:

```bash
# Create the repos directory
mkdir -p ~/repos

# For each repository you work with:
cd ~/repos
git clone --bare git@github.com:username/repo-name.git repo-name
```

### 2. Configuration

The task manager is configured in `lua/plugins/init.lua`:

```lua
require("task-manager").setup({
  jira_prefix = "DEV",
  jira = {
    url = "https://company.atlassian.net",
    email = "you@company.com",
    api_token = function()
      return vim.fn.system("security find-generic-password -s 'Jira API Token' -w")
    end,
    jql = "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC",
    max_results = 50,
  },
  -- tasks_base = vim.fn.expand("~") .. "/tasks",
  -- repos_base = vim.fn.expand("~") .. "/repos",
  -- auto_open = {
  --   callbacks = { "session_restore", "neotree", "outline", "codecompanion" },
  -- },
})
```

`jira.api_token` can return a string or execute a secret retrieval function (e.g. macOS Keychain, 1Password CLI, environment variable). All fields are mandatory and validated during `setup()`.

> **Tip:** The `jira.url` value can include or omit `https://`; it is normalised internally (e.g. `"https://foobar.atlassian.net/"` → `"foobar.atlassian.net"`).

## Usage

### Starting a New Task

**Option 1: From the tasks directory**
```bash
cd ~/tasks
nvim
# Snacks will prompt you to pick an assigned Jira issue or manual entry
```

**Option 2: Using the command**
```vim
:JiraTask 123
" or
:JiraTask DEV-123
```
Passing an argument skips the picker and opens the manual flow pre-filled with the issue you typed.

**Option 3: Using the keybinding**
Press `<leader>tc` to open the Snacks picker. Choose an assigned issue (or the manual option). When an issue is selected its summary is slugified to pre-fill the branch suffix prompt—feel free to edit before confirming.

*The task directory name (e.g. `dev-123-fix-login`) doubles as the git branch name for every worktree in that task. Manual entry prompts first for the issue key, then for the optional suffix.*

#### What happens during the picker step?

- **Assigned issues first:** The picker shows every unresolved Jira issue assigned to you (top entry is always “➕ Manual entry”).
- **Manual fallback:** Choosing the manual entry flows straight into Snacks input boxes so you can type the issue key (`DEV-123`) and an optional suffix.
- **Auto suffix from summary:** If you pick a Jira issue the summary is slugified (e.g. “Fix Login Button” → `fix-login-button`) and pre-filled in the suffix field—edit or delete as needed.
- **Branch & directory naming:** Branches/directories are always `<issue>-<slug>` (lowercased). Selecting “manual” with no suffix just uses the issue key.
- **Abort-friendly:** Closing any picker/input returns `nil` so no directories or worktrees are created until you confirm the suffix prompt.

### Adding Another Repository to a Task

When working on a task that requires changes in multiple repos:

**From within a task directory:**
```vim
:JiraTaskAddRepo
" or press <leader>ta
```

This will:
1. Show a list of available repositories
2. Create a worktree at `~/tasks/dev-123-feature/repo-name/`
3. Check out the branch named `dev-123-feature`

### Navigating Tasks

**List all tasks:**
```vim
:ListTasks
" or press <leader>tt
```

**List repositories within current task:**
```vim
:ListTaskRepos
" or press <leader>tr
```

**Tip:** When you jump into a repo the plugin roots Neo-tree at that worktree so git status indicators stay accurate.

### Resuming Work on a Task

Simply navigate to the task directory and open nvim:

```bash
cd ~/tasks/dev-123
nvim
```

Your session (buffers, windows, CodeCompanion chats) will be automatically restored!

## Cleanup and Deletion

Removing a task directory manually leaves the associated bare repo marked as a "prunable" worktree. To keep things tidy:

- Run `:TaskCleanup` (or pick "🧹 Clean up stale git worktrees" from `:ListTasks`) to prune any orphaned worktrees across all bare repositories.
- Use `:TaskDelete <task-id>` to delete a task, remove its worktrees, and then prune automatically. From the `:ListTasks` picker you can hit `<C-d>` on a task entry to trigger the same flow.

These helpers call `git worktree remove --force`, so make sure you've committed or stashed any local changes before deleting a task.

## Utility Helpers

The module exposes a couple of helpers you can use in your own config:

```lua
local tm = require("task-manager")
if tm.is_tasks_base() then
  -- We're sitting in the task picker root
end

if tm.is_in_tasks_tree() then
  -- Somewhere inside a task workspace
end
```

Both helpers accept an optional path argument if you need to check something other than the current working directory.


## Commands

| Command | Description |
|---------|-------------|
| `:JiraTask <issue>` | Create a new task workspace |
| `:JiraTaskAddRepo` | Add another repository to current task |
| `:ListTasks` | Browse all tasks with Telescope |
| `:ListTaskRepos` | Browse repositories in current task |
| `:TaskCleanup` | Prune stale git worktrees for all bare repos |
| `:TaskDelete [task]` | Remove a task directory and its worktrees |

## Keybindings

| Key | Action |
|-----|--------|
| `<leader>tt` | List all tasks |
| `<leader>tc` | Create new Jira task (with prompt) |
| `<leader>ta` | Add repository to current task |
| `<leader>tr` | List repositories in current task |

## Workflow Example

### Working on DEV-123 that requires changes in api and frontend repos:

1. **Create the task:**
   ```bash
   cd ~/tasks
   nvim
   # Pick the DEV-123 issue from the Snacks picker (or choose manual entry and type "123")
   # When prompted, accept or edit the default suffix (e.g. change to "add-feature")
   # Select "api"
   ```

2. **This creates:**
   - Directory: `~/tasks/dev-123-add-feature/`
   - Worktree: `~/tasks/dev-123-add-feature/api/`
   - Branch: `dev-123-add-feature`

3. **Add the frontend repo:**
   ```vim
   :JiraTaskAddRepo
   # Select "frontend"
   ```

4. **Now you have:**
   ```
   ~/tasks/dev-123-add-feature/
   ├── api/        (branch: dev-123-add-feature)
   └── frontend/   (branch: dev-123-add-feature)
   ```

5. **Switch between repos:**
   - Press `<leader>tr` to see both repos
   - Select one to jump to it

6. **Come back tomorrow:**
   ```bash
   cd ~/tasks/dev-123-add-feature
   nvim  # Everything restores automatically!
   ```

## Integration with Auto-Session

The task manager works seamlessly with `auto-session.nvim`. Each task directory gets its own session, so:

- Buffers are restored per task
- Window layouts persist
- CodeCompanion chat history is maintained
- Each task is completely isolated

## Tips

- **Branch naming**: The branch name always matches the task directory name (e.g. `dev-123-feature`), making it easy to identify which task a branch belongs to
- **Cleaning up**: When done with a task, use `git worktree remove` to clean up worktrees, or just delete the task directory
- **Task isolation**: Each task directory is independent—perfect for Claude Code's directory-based sessions

## Troubleshooting

**"Bare repo not found" error:**
- Ensure your bare repos are in `~/repos/repo-name/` (not `~/repos/repo-name/.bare/`)
- Check that the directory contains `HEAD` and `refs/` (indicators of a bare repo)

**Session not restoring:**
- Ensure `auto-session` plugin is loaded
- Check that you're opening nvim from within the task directory

**No prompt when in ~/tasks:**
- Make sure the task manager is properly loaded
- Check `tasks_base` configuration matches your directory
- Try `:lua print(require('task-manager').config.tasks_base)` to verify

## Advanced: Manual Worktree Management

You can also manage worktrees manually:

```bash
# Create a worktree from bare repo
git --git-dir=~/repos/repo-name worktree add ~/tasks/dev-123/repo-name -b dev-123-feature

# List worktrees for a repo
git --git-dir=~/repos/repo-name worktree list

# Remove a worktree
git --git-dir=~/repos/repo-name worktree remove ~/tasks/dev-123/repo-name
```

## Benefits

- ✅ **Multi-repo tasks**: One workspace for all repos related to a Jira ticket
- ✅ **No branch switching**: Each task has its own isolated branches
- ✅ **Session persistence**: Auto-restore your work environment
- ✅ **Claude Code friendly**: Directory-based sessions work perfectly
- ✅ **Clean separation**: Each task is completely independent
- ✅ **Simple cleanup**: Just delete the task directory when done
