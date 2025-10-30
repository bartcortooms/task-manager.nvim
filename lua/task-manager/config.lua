local task_utils = require("task-manager.task_utils")
local jira = require("task-manager.jira")
local pr = require("task-manager.pr")

local normalize_path = task_utils.normalize_path

local sidekick_cwd_patched = false

local defaults = {
  tasks_base = vim.fn.expand("~") .. "/tasks",
  repos_base = vim.fn.expand("~") .. "/repos",
  jira_prefix = "DEV",
  keymaps = {
    list_tasks = "<leader>tt",
    jira_task = "<leader>tc",
    add_repo = "<leader>ta",
    list_task_repos = "<leader>tr",
    list_prs = "<leader>tpr",
  },
  jira = {
    url = "",
    email = "",
    api_token = function()
      local token = vim.fn.system("security find-generic-password -s 'Jira API Token' -w")
      if vim.v.shell_error ~= 0 then
        return nil
      end
      return token
    end,
    jql = "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC",
    max_results = 50,
  },
}

local current_config = vim.deepcopy(defaults)

local M = {
  defaults = defaults,
}

local function get_claude_cwd()
  local config = current_config or defaults
  local current = vim.fn.getcwd()
  local task_dir = task_utils.resolve_task_dir(current, config.tasks_base)
  if task_dir and task_dir ~= "" then
    return normalize_path(task_dir)
  end

  local tasks_base = normalize_path(config.tasks_base or defaults.tasks_base)
  if tasks_base and tasks_base ~= "" then
    return tasks_base
  end

  return nil
end

local function setup_sidekick_claude_integration()
  if sidekick_cwd_patched then
    return
  end

  local ok, session = pcall(require, "sidekick.cli.session")
  if not ok or type(session.cwd) ~= "function" then
    return
  end

  local original_cwd = session.cwd

  session.cwd = function(opts)
    opts = opts or {}
    if not opts.cwd then
      local tool = opts.tool
      local tool_name = nil
      if type(tool) == "table" then
        tool_name = tool.name
      elseif type(tool) == "string" then
        tool_name = tool
      end

      if tool_name == "claude" then
        local override = get_claude_cwd()
        if override and override ~= "" then
          opts = vim.tbl_extend("force", {}, opts)
          opts.cwd = override
        end
      end
    end

    return original_cwd(opts)
  end

  sidekick_cwd_patched = true
end

function M.get()
  return current_config
end

function M.setup(opts)
  opts = opts or {}

  local merged = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)

  merged.tasks_base = normalize_path(merged.tasks_base)
  merged.repos_base = normalize_path(merged.repos_base)

  vim.validate({
    tasks_base = { merged.tasks_base, "string" },
    repos_base = { merged.repos_base, "string" },
    jira_prefix = { merged.jira_prefix, "string" },
  })

  merged.jira = jira.setup(merged.jira, defaults.jira)

  current_config = merged

  pr.setup({
    get_tasks_base = function()
      return current_config.tasks_base
    end,
  })

  vim.fn.mkdir(current_config.tasks_base, "p")
  vim.fn.mkdir(current_config.repos_base, "p")

  setup_sidekick_claude_integration()

  return current_config
end

return M
