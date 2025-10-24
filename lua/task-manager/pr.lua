local git = require("task-manager.git")
local task_utils = require("task-manager.task_utils")
local ui = require("task-manager.ui")

local M = {}

local state = {
  get_tasks_base = function()
    return nil
  end,
}

function M.setup(opts)
  opts = opts or {}
  if type(opts.get_tasks_base) == "function" then
    state.get_tasks_base = opts.get_tasks_base
  end
end

local function tasks_base()
  return state.get_tasks_base() or ""
end

local function resolve_repo_root(path)
  local base = tasks_base()
  local current = task_utils.normalize_path(path)
  if not current or current == "" then
    return nil
  end

  if vim.fn.isdirectory(current) == 0 then
    current = vim.fn.fnamemodify(current, ":h")
  end

  while current and current ~= "" and current ~= base and current ~= "/" do
    local git_dir = current .. "/.git"
    if vim.fn.isdirectory(git_dir) == 1 or vim.fn.filereadable(git_dir) == 1 then
      return current
    end
    local parent = vim.fn.fnamemodify(current, ":h")
    if parent == current then
      break
    end
    current = parent
  end

  return nil
end

local function resolve_task_dir(path)
  return task_utils.resolve_task_dir(path, tasks_base())
end

local function get_task_repos(task_dir)
  return task_utils.get_task_repos(task_dir)
end

local function ensure_octo_available()
  if vim.fn.exists(":Octo") == 2 then
    return true
  end

  local ok_lazy, lazy = pcall(require, "lazy")
  if ok_lazy then
    pcall(lazy.load, { plugins = { "octo.nvim" } })
  end

  return vim.fn.exists(":Octo") == 2
end

local function run_in_repo(repo_root, command)
  local previous = vim.fn.getcwd()
  local ok_cd, err = pcall(vim.cmd, "lcd " .. vim.fn.fnameescape(repo_root))
  if not ok_cd then
    vim.notify("Failed to change directory to repo: " .. err, vim.log.levels.ERROR)
    return
  end

  local ok, cmd_err = pcall(vim.cmd, command)

  pcall(vim.cmd, "lcd " .. vim.fn.fnameescape(previous))

  if not ok then
    vim.notify("Failed to run " .. command .. ": " .. cmd_err, vim.log.levels.ERROR)
  end
end

local function get_current_repo_root()
  local buf = vim.api.nvim_get_current_buf()
  if buf and buf ~= 0 then
    local name = vim.api.nvim_buf_get_name(buf)
    if name and name ~= "" then
      local repo = resolve_repo_root(name)
      if repo then
        return repo
      end
    end
  end

  local cwd = vim.fn.getcwd()
  local repo_from_cwd = resolve_repo_root(cwd)
  if repo_from_cwd then
    return repo_from_cwd
  end

  local task_dir = resolve_task_dir(cwd)
  if task_dir then
    local repos = get_task_repos(task_dir)
    if #repos == 1 then
      return repos[1].path
    end
  end

  return nil
end

local function gh_available()
  return vim.fn.executable("gh") == 1
end

local function fetch_pr_for_branch(repo_root, branch, repo_slug)
  local fields = { "number", "title", "state", "url", "isDraft", "mergeStateStatus", "headRefName" }
  local cmd = { "gh", "pr", "view", branch }
  if repo_slug then
    table.insert(cmd, "--repo")
    table.insert(cmd, repo_slug)
  end
  table.insert(cmd, "--json")
  table.insert(cmd, table.concat(fields, ","))

  local result = vim.system(cmd, { cwd = repo_root, text = true }):wait()
  if not result then
    return nil, "Failed to execute gh"
  end
  if result.code ~= 0 then
    local stderr = result.stderr or ""
    local stdout = result.stdout or ""
    local combined = stderr ~= "" and stderr or stdout
    if combined:match("no pull requests found") then
      return nil, nil
    end
    return nil, vim.trim(combined ~= "" and combined or ("gh exited with code " .. result.code))
  end

  local ok, decoded = pcall(vim.json.decode, result.stdout or "")
  if not ok then
    return nil, "Failed to parse gh output"
  end
  return decoded, nil
end

local function build_pr_item(entry)
  local branch = entry.branch or git.get_repo_branch(entry.path)
  local repo_slug = git.get_remote_repo(entry.path)
  local item = {
    worktree_name = entry.name,
    repo_root = entry.path,
    branch = branch,
    repo_slug = repo_slug,
    display = entry.name,
  }

  if not branch or branch == "" then
    item.status = "Detached HEAD"
    return item
  end

  local upstream = git.get_upstream_branch(entry.path)
  if upstream then
    item.upstream = upstream
  else
    item.status = "No upstream"
    return item
  end

  if not gh_available() then
    item.status = "Install GitHub CLI (gh)"
    return item
  end

  local pr, err = fetch_pr_for_branch(entry.path, branch, repo_slug)
  if pr then
    item.pr = pr
  elseif err then
    item.error = err
  else
    item.status = "No PR"
  end

  return item
end

local function collect_worktrees_for_context()
  local cwd = vim.fn.getcwd()
  local task_dir = resolve_task_dir(cwd)
  if task_dir then
    return get_task_repos(task_dir), task_dir
  end

  local repo_root = get_current_repo_root()
  if repo_root then
    local branch = git.get_repo_branch(repo_root)
    return {
      {
        name = vim.fn.fnamemodify(repo_root, ":t"),
        path = repo_root,
        branch = branch,
      },
    }, nil
  end

  return {}, nil
end

function M.open_list()
  local repo_root = get_current_repo_root()
  if not repo_root then
    local cwd = vim.fn.getcwd()
    local task_dir = resolve_task_dir(cwd)
    if task_dir then
      local repos = get_task_repos(task_dir)
      if #repos == 0 then
        vim.notify("No repositories attached to this task.", vim.log.levels.WARN)
        return
      end
      ui.list_repos_picker({
        prompt_title = "Select repository for PRs",
        repos = repos,
        on_select = function(repo)
          M.open_list_for_repo(repo.path)
        end,
      })
      return
    end

    vim.notify("Could not determine repository for PR listing.", vim.log.levels.ERROR)
    return
  end

  M.open_list_for_repo(repo_root)
end

function M.open_list_for_repo(repo_root)
  if not ensure_octo_available() then
    vim.notify("Octo.nvim is not available. Please install pwntester/octo.nvim.", vim.log.levels.ERROR)
    return
  end

  run_in_repo(repo_root, "Octo pr list")
end

function M.open_pr_details(item)
  if not item then
    return
  end

  if item.pr and ensure_octo_available() then
    local identifier = item.pr.number or item.pr.headRefName or item.branch
    if identifier then
      run_in_repo(item.repo_root, "Octo pr view " .. identifier)
      return
    end
  end

  if item.pr and gh_available() then
    local identifier = item.pr.number or item.branch
    if identifier then
      vim.system({ "gh", "pr", "view", tostring(identifier), "--web" }, { cwd = item.repo_root, detach = true })
      return
    end
  end

  M.open_list_for_repo(item.repo_root)
end

local function collect_pr_items()
  local worktrees, task_dir = collect_worktrees_for_context()
  if #worktrees == 0 then
    return nil, "No repositories found for PR overview."
  end

  local items = {}
  for _, entry in ipairs(worktrees) do
    local item = build_pr_item(entry)
    item.task_dir = task_dir
    table.insert(items, item)
  end

  return items, nil
end

local function build_pr_nodes(items)
  local nodes = {}
  local max_number = 1
  for _, item in ipairs(items) do
    if item.pr and item.pr.number then
      local repo_slug = item.repo_slug
        or (item.pr.repository and item.pr.repository.nameWithOwner)
        or (item.pr.headRepository and item.pr.headRepository.nameWithOwner)
        or (item.pr.baseRepository and item.pr.baseRepository.nameWithOwner)
        or ""
      if repo_slug ~= "" then
        local base_title = item.pr.title or ""
        local prefix = item.worktree_name and ("[" .. item.worktree_name .. "] ") or ""
        local node = {
          __typename = "PullRequest",
          number = item.pr.number,
          title = prefix .. base_title,
          url = item.pr.url,
          repository = { nameWithOwner = repo_slug },
          headRefName = item.pr.headRefName or item.branch,
          isDraft = item.pr.isDraft,
          state = item.pr.state,
          _task_item = item,
        }
        max_number = math.max(max_number, #tostring(node.number))
        table.insert(nodes, node)
      end
    end
  end
  return nodes, max_number
end

local function show_with_octo_picker(nodes, max_number)
  local entry_maker = require("octo.pickers.telescope.entry_maker")
  local previewers = require("octo.pickers.telescope.previewers")
  local config = require("octo.config")
  local navigation = require("octo.navigation")
  local pickers = require "telescope.pickers"
  local finders = require "telescope.finders"
  local actions = require "telescope.actions"
  local action_state = require "telescope.actions.state"
  local conf = require("telescope.config").values
  local entry_display = require "telescope.pickers.entry_display"

  local entry_fn = entry_maker.gen_from_issue(max_number, true)
  local displayer = entry_display.create {
    separator = " ",
    items = {
      { width = max_number },
      { width = 35 },
      { remaining = true },
    },
  }

  pickers
    .new({}, {
      prompt_title = "Task Pull Requests",
      finder = finders.new_table {
        results = nodes,
        entry_maker = function(node)
          local entry = entry_fn(node)
          if entry then
            entry.tm_item = node._task_item
            local worktree = entry.tm_item and entry.tm_item.worktree_name or entry.repo
            local orig_repo = entry.repo
            entry.display = function()
              return displayer {
                { entry.value, "TelescopeResultsNumber" },
                { worktree or "", "OctoDetailsLabel" },
                { node.title or "" },
              }
            end
            entry.repo = orig_repo
          end
          return entry
        end,
      },
      sorter = conf.generic_sorter({}),
      previewer = previewers.issue.new({}),
      attach_mappings = function(_, map)
        actions.select_default:replace(function(prompt_bufnr)
          local selection = action_state.get_selected_entry(prompt_bufnr)
          actions.close(prompt_bufnr)
          if selection and selection.tm_item then
            M.open_pr_details(selection.tm_item)
          end
        end)

        local mappings = config.values.picker_config.mappings
        if mappings and mappings.open_in_browser then
          map("i", mappings.open_in_browser.lhs, function(prompt_bufnr)
            local selection = action_state.get_selected_entry(prompt_bufnr)
            actions.close(prompt_bufnr)
            if selection and selection.obj then
              navigation.open_in_browser("pull_request", selection.repo, selection.value)
            end
          end)
        end
        return true
      end,
    })
    :find()
end

function M.list_overview()
  local items, err = collect_pr_items()
  if not items then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  local nodes, max_number = build_pr_nodes(items)

  if #nodes > 0 and ensure_octo_available() then
    show_with_octo_picker(nodes, max_number)
    return
  end

  ui.show_pr_overview(items, {
    on_open_pr = function(selected)
      M.open_pr_details(selected)
    end,
    on_open_repo = function(selected)
      M.open_list_for_repo(selected.repo_root)
    end,
  })
end

return M
