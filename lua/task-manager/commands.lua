local config = require("task-manager.config")
local task_utils = require("task-manager.task_utils")
local tasks = require("task-manager.tasks")

local autocmd_registered = false
local keymaps_registered = false
local commands_registered = false
local reveal_lock = false

local function register_autocmds()
  if autocmd_registered then
    return
  end

  local group = vim.api.nvim_create_augroup("TaskManagerAutostart", { clear = true })

  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    callback = function()
      local cwd = vim.fn.getcwd()

      vim.defer_fn(function()
        if tasks.is_tasks_base(cwd) then
          vim.g.in_tasks_directory = true

          vim.defer_fn(function()
            tasks.list_tasks()

            vim.defer_fn(function()
              vim.g.in_tasks_directory = false
            end, 200)
          end, 50)

          return
        end

        if tasks.is_in_tasks_tree(cwd) then
          local base = config.get().tasks_base
          local relative = cwd:gsub("^" .. vim.pesc(base) .. "/?", "")
          local task_name = relative:match("([^/]+)")
          if task_name and task_name ~= "" then
            vim.notify("Working on task: " .. task_name:upper(), vim.log.levels.INFO)
          end
        end
      end, 100)
    end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      if reveal_lock then
        return
      end

      local buf = args.buf
      if not buf or buf == 0 then
        return
      end

      local name = vim.api.nvim_buf_get_name(buf)
      if not name or name == "" then
        return
      end

      local cfg = config.get()
      if not task_utils.is_path_inside(name, cfg.tasks_base) then
        return
      end

      local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })
      if buftype ~= "" then
        return
      end

      reveal_lock = true
      vim.defer_fn(function()
        pcall(tasks.reveal_path_in_tree, name)
        reveal_lock = false
      end, 25)
    end,
  })

  autocmd_registered = true
end

local function register_keymaps()
  if keymaps_registered then
    return
  end

  local keymaps = config.get().keymaps or {}
  local map = vim.keymap.set

  local function set_map(lhs, rhs, desc)
    if not lhs or lhs == "" then
      return
    end
    map("n", lhs, rhs, { desc = desc, silent = true })
  end

  set_map(keymaps.jira_task, function()
    tasks.create_task()
  end, "Task Manager: Create Jira task")

  set_map(keymaps.add_repo, function()
    tasks.add_repo_to_task()
  end, "Task Manager: Add repository to task")

  set_map(keymaps.list_tasks, function()
    tasks.list_tasks()
  end, "Task Manager: List tasks")

  set_map(keymaps.list_task_repos, function()
    tasks.list_task_repos()
  end, "Task Manager: List task repositories")

  set_map(keymaps.list_prs, function()
    local pr = require("task-manager.pr")
    pr.list_overview()
  end, "Task Manager: PR overview")

  keymaps_registered = true
end

local function register_user_commands()
  if commands_registered then
    return
  end

  vim.api.nvim_create_user_command("JiraTask", function(cmd_opts)
    local arg = cmd_opts.args
    if arg == "" then
      tasks.create_task()
    else
      tasks.create_task(arg)
    end
  end, {
    nargs = "?",
    desc = "Create new task from Jira issue",
  })

  vim.api.nvim_create_user_command("JiraTaskAddRepo", function()
    tasks.add_repo_to_task()
  end, {
    desc = "Add another repo to current task",
  })

  vim.api.nvim_create_user_command("ListTasks", function()
    tasks.list_tasks()
  end, {
    desc = "List all Jira tasks",
  })

  vim.api.nvim_create_user_command("ListTaskRepos", function()
    tasks.list_task_repos()
  end, {
    desc = "List repos in current task",
  })

  vim.api.nvim_create_user_command("TaskPRs", function()
    local pr = require("task-manager.pr")
    pr.list_overview()
  end, {
    desc = "Show GitHub PR overview for current task",
  })

  vim.api.nvim_create_user_command("TaskPROcto", function()
    local pr = require("task-manager.pr")
    pr.open_list()
  end, {
    desc = "Open Octo PR list for current repo/task",
  })

  vim.api.nvim_create_user_command("TaskCleanup", function()
    tasks.cleanup_stale_worktrees()
  end, {
    desc = "Prune stale git worktrees for tasks",
  })

  vim.api.nvim_create_user_command("TaskDelete", function(cmd_opts)
    local target = cmd_opts.args
    if target == "" then
      local cfg = config.get()
      local cwd = vim.fn.getcwd()
      local pattern = "^" .. vim.pesc(cfg.tasks_base) .. "/([^/]+)"
      target = cwd:match(pattern) or ""
    end

    if target == "" then
      vim.notify("Provide a task ID or run :TaskDelete from within a task directory", vim.log.levels.WARN)
      return
    end

    tasks.prompt_delete_task(target)
  end, {
    nargs = "?",
    complete = function()
      local names = {}
      local cfg = config.get()
      for _, task in ipairs(task_utils.get_tasks(cfg.tasks_base)) do
        table.insert(names, task.name)
      end
      return names
    end,
    desc = "Delete a task directory and its git worktrees",
  })

  commands_registered = true
end

local M = {}

function M.setup()
  register_autocmds()
  register_keymaps()
  register_user_commands()
end

return M
