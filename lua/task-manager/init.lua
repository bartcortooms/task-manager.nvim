local config = require("task-manager.config")
local tasks = require("task-manager.tasks")
local commands = require("task-manager.commands")

local M = {
  defaults = config.defaults,
  config = config.get(),
}

local exported_functions = {
  "get_available_repos",
  "reveal_path_in_tree",
  "is_tasks_base",
  "is_in_tasks_tree",
  "create_repo_worktree",
  "create_task",
  "add_repo_to_task",
  "list_tasks",
  "list_task_repos",
  "cleanup_stale_worktrees",
  "delete_task",
  "prompt_delete_task",
}

for _, name in ipairs(exported_functions) do
  M[name] = tasks[name]
end

function M.setup(opts)
  local cfg = config.setup(opts)
  M.config = cfg
  commands.setup()
  return cfg
end

return M
