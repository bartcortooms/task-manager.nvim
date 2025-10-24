
local jira = require("task-manager.jira")
local git = require("task-manager.git")
local worktree = require("task-manager.worktree")
local task_utils = require("task-manager.task_utils")
local ui = require("task-manager.ui")

local normalize_path = task_utils.normalize_path
local normalize_and_compare = task_utils.normalize_and_compare
local slugify = task_utils.slugify
local build_task_name = task_utils.build_task_name
local parse_issue_string = task_utils.parse_issue_string
local is_path_inside = task_utils.is_path_inside
local get_task_repos = task_utils.get_task_repos

local defaults = {
  -- Base directory for tasks (each task gets its own directory)
  tasks_base = vim.fn.expand("~") .. "/tasks",
  -- Bare repos directory (where your .bare git repos live)
  repos_base = vim.fn.expand("~") .. "/repos",
  -- Jira issue prefix (e.g., "DEV", "PROJ")
  jira_prefix = "DEV",
  -- Optional keymaps (set to false/nil/"" to disable a specific mapping)
  keymaps = {
    list_tasks = "<leader>tt",
    jira_task = "<leader>tc",
    add_repo = "<leader>ta",
    list_task_repos = "<leader>tr",
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

local M = {
  defaults = defaults,
  config = vim.deepcopy(defaults),
}

local autocmd_registered = false
local keymaps_registered = false
local reveal_lock = false

local function restore_auto_session()
  local ok, auto_session = pcall(require, "auto-session")
  if not ok then
    return
  end

  pcall(auto_session.restore_session, nil, { show_message = false })
end

local function get_tasks()
  return task_utils.get_tasks(M.config.tasks_base)
end

local function resolve_task_identifier(task)
  return task_utils.resolve_task_identifier(task, M.config.tasks_base)
end

local function resolve_task_dir(path)
  return task_utils.resolve_task_dir(path, M.config.tasks_base)
end

-- Helper: Get list of available bare repos
function M.get_available_repos()
  local repos = {}
  local handle = vim.loop.fs_scandir(M.config.repos_base)
  if handle then
    while true do
      local name, type = vim.loop.fs_scandir_next(handle)
      if not name then break end

      -- Check if it's a directory and is a bare repo (has HEAD and refs)
      local bare_path = M.config.repos_base .. "/" .. name
      local head_file = bare_path .. "/HEAD"
      local refs_dir = bare_path .. "/refs"
      if type == "directory" and vim.fn.filereadable(head_file) == 1 and vim.fn.isdirectory(refs_dir) == 1 then
        -- Strip .git suffix if present
        local repo_name = name:gsub("%.git$", "")
        table.insert(repos, {
          name = repo_name,
          path = bare_path,
        })
      end
    end
  end
  return repos
end

local function load_neotree_command()
  local ok_lazy, lazy = pcall(require, "lazy")
  if ok_lazy then
    lazy.load({ plugins = { "neo-tree.nvim" } })
  end

  local ok, command = pcall(require, "neo-tree.command")
  if not ok then
    return nil
  end

  return command
end


local function resolve_repo_root(path)
  local current = normalize_path(path)
  if not current then
    return nil
  end

  if vim.fn.isdirectory(current) == 0 then
    current = vim.fn.fnamemodify(current, ":h")
  end

  while current and current ~= "" and current ~= M.config.tasks_base and current ~= "/" do
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

function M.reveal_path_in_tree(path)
  if not path or path == "" then
    return
  end

  local normalized = normalize_path(path)
  if not normalized then
    return
  end

  if not is_path_inside(normalized, M.config.tasks_base) then
    return
  end

  local command = load_neotree_command()
  if not command then
    return
  end

  local repo_root = resolve_repo_root(normalized)
  local tree_root = repo_root or resolve_task_dir(normalized) or normalize_path(M.config.tasks_base)

  local manager = require("neo-tree.sources.manager")
  local renderer = require("neo-tree.ui.renderer")
  local fs_source = require("neo-tree.sources.filesystem")

  local state = manager.get_state("filesystem")
  if state and renderer.window_exists(state) then
    fs_source.navigate(state, tree_root, normalized, nil, true)
  else
    if state and state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
      renderer.close(state, false)
      state = manager.get_state("filesystem")
    end
    command.execute({
      action = "show",
      source = "filesystem",
      position = "left",
      dir = tree_root,
      reveal = true,
      reveal_file = normalized,
    })
  end
end

---Return true when the given path (or current working directory) equals the
---tasks base configured for the task manager.
---@param dir? string
---@return boolean
function M.is_tasks_base(dir)
  return normalize_and_compare(dir or vim.fn.getcwd(), M.config.tasks_base)
end

---Return true if the given path (or current working directory) lives inside the
---configured tasks tree (base directory or any child).
---@param dir? string
---@return boolean
function M.is_in_tasks_tree(dir)
  local base = normalize_path(M.config.tasks_base)
  local target = normalize_path(dir or vim.fn.getcwd())
  if not base or base == "" or not target then
    return false
  end
  if target == base then
    return true
  end
  return target:sub(1, #base + 1) == base .. "/"
end

-- Helper: Create worktree for a repo in task directory
function M.create_repo_worktree(task_dir, repo_obj, branch_name)
  return worktree.create(task_dir, repo_obj, branch_name)
end


local function finalize_task(issue_key, suffix)
  local task_dir_name = build_task_name(issue_key, suffix or "")
  local task_dir = M.config.tasks_base .. "/" .. task_dir_name

  if vim.fn.isdirectory(task_dir) == 0 then
    vim.fn.mkdir(task_dir, "p")
    vim.notify("Created task directory: " .. task_dir, vim.log.levels.INFO)
  end

  local label = issue_key
  if suffix and suffix ~= "" then
    label = label .. " · " .. suffix
  end

  local repos = M.get_available_repos()
  ui.show_repo_menu({
    repos = repos,
    task_label = label,
    task_dir = task_dir,
    on_empty = function()
      vim.notify("No bare repos found in " .. M.config.repos_base, vim.log.levels.WARN)
      vim.notify("Task directory created, but no worktrees added", vim.log.levels.INFO)
      vim.cmd("cd " .. vim.fn.fnameescape(task_dir))
    end,
    on_select = function(selected_repo)
      local branch_name = task_dir_name
      if M.create_repo_worktree(task_dir, selected_repo, branch_name) then
        vim.notify("Created worktree: " .. selected_repo.name .. " (" .. branch_name .. ")", vim.log.levels.INFO)
        local worktree_path = task_dir .. "/" .. selected_repo.name
        vim.cmd("cd " .. vim.fn.fnameescape(worktree_path))
        restore_auto_session()
        M.reveal_path_in_tree(worktree_path)
      end
    end,
  })
end

local function prompt_suffix(issue_key, default_suffix)
  ui.prompt_suffix({
    default_suffix = default_suffix or "",
    on_submit = function(suffix)
      finalize_task(issue_key, suffix)
    end,
  })
end

local function prompt_manual_issue(default_issue, default_suffix)
  ui.prompt_issue_key({
    default_issue = default_issue,
    jira_prefix = M.config.jira_prefix,
    parse_issue_string = parse_issue_string,
    on_invalid = function()
      vim.notify("Issue key is required", vim.log.levels.ERROR)
      prompt_manual_issue(default_issue, default_suffix)
    end,
    on_submit = function(issue_key, inline_suffix)
      local suffix_hint = inline_suffix ~= "" and inline_suffix or (default_suffix or "")
      prompt_suffix(issue_key, suffix_hint)
    end,
  })
end

function M.create_task(issue_number)
  if issue_number and issue_number ~= "" then
    local issue_key, suffix = parse_issue_string(issue_number, M.config.jira_prefix)
    if not issue_key then
      vim.notify("Issue key is required", vim.log.levels.ERROR)
      return
    end
    prompt_manual_issue(issue_key, suffix)
    return
  end

  local entries = {
    { label = "➕ Manual entry", issue = nil },
  }

  local issues, fetch_err = jira.fetch_assigned_issues()
  if not issues then
    if fetch_err and fetch_err ~= "" then
      vim.notify(fetch_err, vim.log.levels.ERROR)
    end
  else
    if #issues == 0 then
      vim.notify("No assigned Jira issues found for the configured JQL.", vim.log.levels.INFO)
    end
    for _, issue in ipairs(issues) do
      local summary = issue.summary or ""
      local label = string.format("%s  |  %s", issue.key, summary)
      table.insert(entries, {
        label = label,
        issue = issue,
      })
    end
  end

  ui.pick_issue({
    entries = entries,
    on_manual = function()
      prompt_manual_issue(nil, nil)
    end,
    on_issue = function(issue)
      local issue_key = issue.key
      if not issue_key or issue_key == "" then
        vim.notify("Selected Jira issue is missing a key", vim.log.levels.ERROR)
        return
      end

      local suffix_hint = slugify(issue.summary or "")
      prompt_suffix(issue_key:upper(), suffix_hint)
    end,
  })
end


function M.add_repo_to_task()
  local cwd = vim.fn.getcwd()
  local task_dir = resolve_task_dir(cwd)

  -- Check if we're in a task directory
  if not task_dir then
    vim.notify("Not in a task directory. Run :JiraTask first", vim.log.levels.ERROR)
    return
  end

  local task_id = vim.fn.fnamemodify(task_dir, ":t")
  local repos = M.get_available_repos()

  ui.show_repo_menu({
    repos = repos,
    task_label = task_id:upper(),
    task_dir = task_dir,
    on_empty = function()
      vim.notify("No bare repos found in " .. M.config.repos_base, vim.log.levels.WARN)
    end,
    on_select = function(selected_repo)
      local branch_name = task_id
      if M.create_repo_worktree(task_dir, selected_repo, branch_name) then
        vim.notify("Added worktree: " .. selected_repo.name .. " (" .. branch_name .. ")", vim.log.levels.INFO)
        local worktree_path = task_dir .. "/" .. selected_repo.name
        vim.cmd("cd " .. vim.fn.fnameescape(worktree_path))
        restore_auto_session()
        M.reveal_path_in_tree(worktree_path)
      end
    end,
  })
end

-- List all tasks with Telescope
function M.list_tasks()
  local entries = {
    {
      display = "➕ Create new task",
      ordinal = "create",
      kind = "create",
    },
    {
      display = "🧹 Clean up stale git worktrees",
      ordinal = "cleanup",
      kind = "cleanup",
    },
  }

  local tasks = get_tasks()
  for _, task in ipairs(tasks) do
    table.insert(entries, {
      display = task.name,
      ordinal = task.name,
      kind = "task",
      task = task,
    })
  end

  ui.list_tasks_picker({
    prompt_title = "Jira Tasks",
    entries = entries,
    on_delete = function(task)
      M.prompt_delete_task(task)
    end,
    on_select = function(entry)
      if entry.kind == "create" then
        M.create_task()
      elseif entry.kind == "cleanup" then
        M.cleanup_stale_worktrees()
      elseif entry.kind == "task" and entry.task then
        vim.cmd("cd " .. vim.fn.fnameescape(entry.task.path))
        vim.notify("Switched to task: " .. entry.task.name, vim.log.levels.INFO)
        restore_auto_session()
        M.reveal_path_in_tree(entry.task.path)
      end
    end,
  })
end

-- List repos within current task
function M.list_task_repos()
  local cwd = vim.fn.getcwd()

  -- Find the task root (might be in a subdirectory)
  local task_dir = resolve_task_dir(cwd)
  if not task_dir then
    vim.notify("Not in a task directory", vim.log.levels.ERROR)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  -- Get all repo directories in task
  local repos = get_task_repos(task_dir)

  if #repos == 0 then
    vim.notify("No repositories in this task", vim.log.levels.WARN)
    return
  end

  ui.list_repos_picker({
    repos = repos,
    on_select = function(repo)
      vim.cmd("cd " .. vim.fn.fnameescape(repo.path))
      vim.notify("Switched to repo: " .. repo.name, vim.log.levels.INFO)
      restore_auto_session()
      M.reveal_path_in_tree(repo.path)
    end,
  })
end


function M.cleanup_stale_worktrees(opts)
  opts = opts or {}
  local repos = M.get_available_repos()
  if #repos == 0 then
    if not opts.silent then
      vim.notify("No bare repositories configured for task manager", vim.log.levels.INFO)
    end
    return { pruned = 0, failures = {} }
  end

  local pruned = 0
  local failures = {}

  for _, repo in ipairs(repos) do
    local ok, message = git.prune_worktrees(repo, { silent = true })
    if ok then
      pruned = pruned + 1
    else
      table.insert(failures, repo.name .. ": " .. (message or "git worktree prune failed"))
    end
  end

  if not opts.silent then
    if #failures == 0 then
      vim.notify("Pruned stale worktrees across " .. pruned .. " repo(s)", vim.log.levels.INFO)
    else
      vim.notify(
        "Pruned stale worktrees for " .. pruned .. " repo(s); failed for " .. #failures .. ":\n" .. table.concat(failures, "\n"),
        vim.log.levels.WARN
      )
    end
  end

  return { pruned = pruned, failures = failures }
end

function M.delete_task(task, opts)
  opts = opts or {}
  local task_name, task_path = resolve_task_identifier(task)
  if not task_name or not task_path then
    if not opts.silent then
      vim.notify("Invalid task selection", vim.log.levels.ERROR)
    end
    return false
  end

  if vim.fn.isdirectory(task_path) == 0 then
    if not opts.silent then
      vim.notify("Task directory not found: " .. task_name, vim.log.levels.WARN)
    end
    return false
  end

  local repos = M.get_available_repos()
  local repo_lookup = {}
  for _, repo in ipairs(repos) do
    repo_lookup[repo.name] = repo
  end

  local handle = vim.loop.fs_scandir(task_path)
  local removed = {}
  local failures = {}
  if handle then
    while true do
      local name, type = vim.loop.fs_scandir_next(handle)
      if not name then
        break
      end
      if type == "directory" and name ~= ".git" then
        local worktree_path = task_path .. "/" .. name
        local repo = repo_lookup[name]
        if repo then
          local code, output = git.run_git(repo.path, { "worktree", "remove", "--force", worktree_path })
          if code ~= 0 then
            table.insert(failures, repo.name .. ": " .. (output ~= "" and output or "git worktree remove failed"))
          else
            table.insert(removed, name)
          end
        else
          if not opts.silent then
            vim.notify("No bare repo registered for '" .. name .. "'; deleting directory only", vim.log.levels.WARN)
          end
        end
      end
    end
  end

  local cwd = vim.fn.getcwd()
  if is_path_inside(cwd, task_path) then
    vim.cmd("cd " .. vim.fn.fnameescape(M.config.tasks_base))
  end

  vim.fn.delete(task_path, "rf")

  if opts.prune ~= false then
    M.cleanup_stale_worktrees({ silent = true })
  end

  if not opts.silent then
    if #failures == 0 then
      vim.notify("Deleted task " .. task_name:upper() .. " (" .. #removed .. " worktree(s) removed)", vim.log.levels.INFO)
    else
      vim.notify(
        "Deleted task " .. task_name:upper() .. " but some worktrees failed to remove:\n" .. table.concat(failures, "\n"),
        vim.log.levels.WARN
      )
    end
  end

  return true
end

function M.prompt_delete_task(task)
  local task_name = task
  if type(task) == "table" and task.name then
    task_name = task.name
  end

  if not task_name or task_name == "" then
    vim.notify("No task selected", vim.log.levels.WARN)
    return
  end

  local _, task_path = resolve_task_identifier(task_name)
  if vim.fn.isdirectory(task_path) == 0 then
    vim.notify("Task directory not found: " .. task_name, vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = "Delete task " .. task_name:upper() .. "? Type 'yes' to confirm: " }, function(answer)
    if answer and answer:lower():match("^y") then
      M.delete_task(task_name)
    else
      vim.notify("Task deletion cancelled", vim.log.levels.INFO)
    end
  end)
end


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
        if M.is_tasks_base and M.is_tasks_base(cwd) then
          vim.g.in_tasks_directory = true

          vim.defer_fn(function()
            if M.list_tasks then
              M.list_tasks()
            end

            vim.defer_fn(function()
              vim.g.in_tasks_directory = false
            end, 200)
          end, 50)

          return
        end

        if M.is_in_tasks_tree and M.is_in_tasks_tree(cwd) then
          local base = M.config.tasks_base
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

      if not is_path_inside(name, M.config.tasks_base) then
        return
      end

      local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })
      if buftype ~= "" then
        return
      end

      reveal_lock = true
      vim.defer_fn(function()
        pcall(M.reveal_path_in_tree, name)
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

  local keymaps = M.config.keymaps or {}
  local map = vim.keymap.set

  local function set_map(lhs, rhs, desc)
    if not lhs or lhs == "" then
      return
    end
    map("n", lhs, rhs, { desc = desc, silent = true })
  end

  set_map(keymaps.jira_task, function()
    M.create_task()
  end, "Task Manager: Create Jira task")

  set_map(keymaps.add_repo, function()
    M.add_repo_to_task()
  end, "Task Manager: Add repository to task")

  set_map(keymaps.list_tasks, function()
    M.list_tasks()
  end, "Task Manager: List tasks")

  set_map(keymaps.list_task_repos, function()
    M.list_task_repos()
  end, "Task Manager: List task repositories")

  keymaps_registered = true
end

-- Setup function to register commands
function M.setup(opts)
  opts = opts or {}

  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)

  merged.tasks_base = normalize_path(merged.tasks_base)
  merged.repos_base = normalize_path(merged.repos_base)

  vim.validate({
    tasks_base = { merged.tasks_base, "string" },
    repos_base = { merged.repos_base, "string" },
    jira_prefix = { merged.jira_prefix, "string" },
  })

  merged.jira = jira.setup(merged.jira, defaults.jira)

  M.config = merged

  -- Ensure base directories exist
  vim.fn.mkdir(M.config.tasks_base, "p")
  vim.fn.mkdir(M.config.repos_base, "p")

  -- Register commands
  vim.api.nvim_create_user_command("JiraTask", function(cmd_opts)
    local arg = cmd_opts.args
    if arg == "" then
      M.create_task()
    else
      M.create_task(arg)
    end
  end, {
    nargs = "?",
    desc = "Create new task from Jira issue",
  })

  vim.api.nvim_create_user_command("JiraTaskAddRepo", function()
    M.add_repo_to_task()
  end, {
    desc = "Add another repo to current task",
  })

  vim.api.nvim_create_user_command("ListTasks", function()
    M.list_tasks()
  end, {
    desc = "List all Jira tasks",
  })

  vim.api.nvim_create_user_command("ListTaskRepos", function()
    M.list_task_repos()
  end, {
    desc = "List repos in current task",
  })


  vim.api.nvim_create_user_command("TaskCleanup", function()
    M.cleanup_stale_worktrees()
  end, {
    desc = "Prune stale git worktrees for tasks",
  })

  vim.api.nvim_create_user_command("TaskDelete", function(cmd_opts)
    local target = cmd_opts.args
    if target == "" then
      local cwd = vim.fn.getcwd()
      local pattern = "^" .. vim.pesc(M.config.tasks_base) .. "/([^/]+)"
      target = cwd:match(pattern) or ""
    end

    if target == "" then
      vim.notify("Provide a task ID or run :TaskDelete from within a task directory", vim.log.levels.WARN)
      return
    end

    M.prompt_delete_task(target)
  end, {
    nargs = "?",
    complete = function()
      local names = {}
      for _, task in ipairs(get_tasks()) do
        table.insert(names, task.name)
      end
      return names
    end,
    desc = "Delete a task directory and its git worktrees",
  })

  register_autocmds()
  register_keymaps()

  return M.config
end

return M
