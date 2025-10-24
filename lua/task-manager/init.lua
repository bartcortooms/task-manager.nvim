
local jira = require("task-manager.jira")

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

local function run_command(cmd_args)
  if vim.system then
    local obj = vim.system(cmd_args, { text = true }):wait()
    local output = obj.stdout or ""
    local err = obj.stderr or ""
    if err ~= "" then
      if output ~= "" then
        output = output .. "\n" .. err
      else
        output = err
      end
    end
    return obj.code, vim.trim(output)
  end

  local stdout = {}
  local stderr = {}
  local job_id = vim.fn.jobstart(cmd_args, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(stdout, line)
        end
      end
    end,
    on_stderr = function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(stderr, line)
        end
      end
    end,
  })

  if job_id <= 0 then
    return job_id, "Failed to start git process"
  end

  local result = vim.fn.jobwait({ job_id }, -1)
  local code = result[1]

  local output = table.concat(stdout, "\n")
  local err = table.concat(stderr, "\n")
  if err ~= "" then
    if output ~= "" then
      output = output .. "\n" .. err
    else
      output = err
    end
  end

  return code, vim.trim(output)
end

local function run_git(bare_repo, args)
  local cmd = { "git", "--git-dir=" .. bare_repo }
  vim.list_extend(cmd, args)
  return run_command(cmd)
end

local function normalize_path(path)
  if not path or path == "" then
    return path
  end
  local expanded = vim.fn.expand(path)
  if expanded ~= "/" then
    expanded = expanded:gsub("/+", "/")
    expanded = expanded:gsub("/$", "")
  end
  return expanded
end

local function normalize_and_compare(a, b)
  local na = normalize_path(a)
  local nb = normalize_path(b)
  if not na or not nb then
    return false
  end
  return na == nb
end

local function slugify(str)
  str = str or ""
  str = str:lower()
  str = str:gsub("%s+", "-")
  str = str:gsub("[^%w%-]", "-")
  str = str:gsub("%-+", "-")
  str = str:gsub("^%-", "")
  str = str:gsub("%-$", "")
  return str
end

local function build_task_name(issue_key, suffix)
  if suffix and suffix ~= "" then
    return string.format("%s-%s", issue_key:lower(), slugify(suffix))
  end
  return issue_key:lower()
end

local function parse_issue_string(value, jira_prefix)
  if not value then
    return nil, ""
  end

  value = vim.trim(value)
  if value == "" then
    return nil, ""
  end

  if not value:match("^[A-Za-z]+%-") then
    if jira_prefix and jira_prefix ~= "" then
      value = jira_prefix .. "-" .. value
    end
  end

  value = value:upper()
  local issue_key = value
  local suffix = ""

  local key_only, extra = value:match("^([%w%-]+%-%d+)%-(.+)$")
  if not key_only then
    key_only, extra = value:match("^([%w%-]+%-%d+)%s+(.+)$")
  end
  if key_only then
    issue_key = key_only
    suffix = slugify(extra)
  end

  return issue_key, suffix
end

local function restore_auto_session()
  local ok, auto_session = pcall(require, "auto-session")
  if not ok then
    return
  end

  pcall(auto_session.restore_session, nil, { show_message = false })
end

local function get_tasks()
  local tasks = {}
  local handle = vim.loop.fs_scandir(M.config.tasks_base)
  if handle then
    while true do
      local name, type = vim.loop.fs_scandir_next(handle)
      if not name then
        break
      end
      if type == "directory" then
        table.insert(tasks, {
          name = name,
          path = M.config.tasks_base .. "/" .. name,
        })
      end
    end
  end

  table.sort(tasks, function(a, b)
    return a.name < b.name
  end)

  return tasks
end

local function prune_repo_worktrees(repo, opts)
  opts = opts or {}
  local code, output = run_git(repo.path, { "worktree", "prune", "--expire=now" })
  if code ~= 0 then
    local message = output ~= "" and output or "git worktree prune failed"
    if not opts.silent then
      vim.notify("Failed to prune worktrees for " .. repo.name .. ": " .. message, vim.log.levels.ERROR)
    end
    return false, message
  end
  return true
end


local function resolve_task_identifier(task)
  if type(task) == "table" and task.name and task.path then
    return task.name, task.path
  end

  if type(task) == "string" and task ~= "" then
    local normalized = task:lower()
    local path = M.config.tasks_base .. "/" .. normalized
    return normalized, path
  end

  return nil, nil
end

local function is_path_inside(path, root)
  if not path or not root then
    return false
  end
  if path == root then
    return true
  end
  if root:sub(-1) ~= "/" then
    root = root .. "/"
  end
  return path:sub(1, #root) == root
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

local function resolve_task_dir(path)
  local base = normalize_path(M.config.tasks_base)
  local target = normalize_path(path or vim.fn.getcwd())
  if not base or base == "" or not target or target == base then
    return nil
  end
  if target:sub(1, #base) ~= base then
    return nil
  end

  local task_dir = target
  while task_dir ~= base and vim.fn.fnamemodify(task_dir, ":h") ~= base do
    task_dir = vim.fn.fnamemodify(task_dir, ":h")
  end

  if vim.fn.fnamemodify(task_dir, ":h") == base then
    return task_dir
  end

  return nil
end

local function get_repo_branch(path)
  local code, output = run_command({ "git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD" })
  if code ~= 0 then
    return nil
  end
  if output == "HEAD" then
    -- Detached HEAD; try to show short commit hash
    local _, commit = run_command({ "git", "-C", path, "rev-parse", "--short", "HEAD" })
    return commit ~= "" and ("detached@" .. commit) or "detached"
  end
  return output
end

local function get_task_repos(task_dir)
  local repos = {}
  local handle = vim.loop.fs_scandir(task_dir)
  if handle then
    while true do
      local name, type = vim.loop.fs_scandir_next(handle)
      if not name then
        break
      end
      if type == "directory" and name ~= ".git" then
        local path = task_dir .. "/" .. name
        table.insert(repos, {
          name = name,
          path = path,
          branch = get_repo_branch(path),
        })
      end
    end
  end

  table.sort(repos, function(a, b)
    return a.name < b.name
  end)

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
  local bare_repo = repo_obj.path
  local repo_name = repo_obj.name

  -- Check if bare repo exists
  if vim.fn.isdirectory(bare_repo) == 0 then
    vim.notify("Bare repo not found: " .. bare_repo, vim.log.levels.ERROR)
    return false
  end

  local worktree_path = task_dir .. "/" .. repo_name

  -- Prevent accidentally reusing an existing directory
  if vim.fn.isdirectory(worktree_path) == 1 then
    vim.notify("Worktree directory already exists: " .. worktree_path, vim.log.levels.WARN)
    return false
  end

  -- Check if branch already exists in the bare repo
  local branch_exists = false
  local branch_code, branch_output = run_git(bare_repo, { "rev-parse", "--verify", "--quiet", branch_name })
  if branch_code == 0 then
    branch_exists = true
  elseif branch_code ~= 1 then
    local message = branch_output ~= "" and branch_output or "git rev-parse failed"
    vim.notify("Failed to inspect branch: " .. message, vim.log.levels.ERROR)
    return false
  end

  -- If branch exists, ensure it's not already checked out in another worktree
  if branch_exists then
    local list_code, list_output = run_git(bare_repo, { "worktree", "list", "--porcelain" })
    if list_code ~= 0 then
      local message = list_output ~= "" and list_output or "git worktree list failed"
      vim.notify("Failed to inspect existing worktrees: " .. message, vim.log.levels.ERROR)
      return false
    end

    local current = { branch = nil, prunable = false, path = nil }
    local prunable_entry = nil

    for line in string.gmatch(list_output .. "\n", "([^\n]*)\n") do
      if line == "" then
        if current.branch then
          local branch = current.branch:gsub("^refs/heads/", "")
          if branch == branch_name then
            if current.prunable then
              prunable_entry = current
            else
              vim.notify("Branch '" .. branch_name .. "' already checked out in another worktree", vim.log.levels.ERROR)
              return false
            end
          end
        end
        current = { branch = nil, prunable = false, path = nil }
      else
        local path_line = line:match("^worktree%s+(.+)$")
        if path_line then
          current.path = path_line
        else
          local ref = line:match("^branch%s+(.+)$")
          if ref then
            current.branch = ref
          elseif line:match("^prunable") then
            current.prunable = true
          end
        end
      end
    end

    if prunable_entry then
      if prunable_entry.path then
        local remove_code, remove_output = run_git(bare_repo, { "worktree", "remove", "--force", prunable_entry.path })
        if remove_code ~= 0 then
          local message = remove_output ~= "" and remove_output or "git worktree remove failed"
          vim.notify("Failed to remove stale worktree at " .. prunable_entry.path .. ": " .. message, vim.log.levels.ERROR)
          return false
        end
      end

      local ok = prune_repo_worktrees({ name = repo_name, path = bare_repo }, { silent = true })
      if ok == false then
        return false
      end

      local recheck_code, recheck_output = run_git(bare_repo, { "worktree", "list", "--porcelain" })
      if recheck_code == 0 then
        for line in string.gmatch(recheck_output .. "\n", "([^\n]*)\n") do
          local ref = line:match("^branch%s+(.+)$")
          if ref and ref:gsub("^refs/heads/", "") == branch_name then
            vim.notify("Branch '" .. branch_name .. "' still appears in worktree list after cleanup", vim.log.levels.ERROR)
            return false
          end
        end
      end
    end
  end

  -- Create worktree using git command
  local args
  if branch_exists then
    args = { "worktree", "add", worktree_path, branch_name }
  else
    args = { "worktree", "add", worktree_path, "-b", branch_name }
  end

  local code, output = run_git(bare_repo, args)
  if code ~= 0 then
    local message = output ~= "" and output or "git worktree add failed"
    vim.notify("Failed to create worktree: " .. message, vim.log.levels.ERROR)
    return false
  end

  return true
end

-- Create a new task with multi-repo support
local function show_repo_selection(task_label, task_dir, task_dir_name)
  local repos = M.get_available_repos()
  if #repos == 0 then
    vim.notify("No bare repos found in " .. M.config.repos_base, vim.log.levels.WARN)
    vim.notify("Task directory created, but no worktrees added", vim.log.levels.INFO)
    vim.cmd("cd " .. vim.fn.fnameescape(task_dir))
    return
  end

  local Menu = require("nui.menu")

  local menu_items = {}
  for _, repo in ipairs(repos) do
    menu_items[#menu_items + 1] = Menu.item("📦 " .. repo.name, { repo = repo })
  end

  local menu = Menu({
    position = "50%",
    size = {
      width = 50,
      height = math.min(#menu_items + 2, 15),
    },
    border = {
      style = "rounded",
      text = {
        top = " Select Repository for " .. task_label .. " ",
        top_align = "center",
      },
    },
  }, {
    lines = menu_items,
    max_width = 48,
    keymap = {
      focus_next = { "j", "<Down>", "<Tab>" },
      focus_prev = { "k", "<Up>", "<S-Tab>" },
      close = { "<Esc>", "<C-c>", "q" },
      submit = { "<CR>", "<Space>" },
    },
    on_submit = function(item)
      local selected_repo = item.repo
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

  menu:mount()
end

local function pick_issue(callback)
  local Snacks = require("snacks")

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

  local items = vim.tbl_map(function(entry)
    return { label = entry.label, issue = entry.issue }
  end, entries)

  Snacks.picker.select(items, {
    prompt = "Select Jira issue",
    filter = "fuzzy",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not callback then
      return
    end

    if not choice then
      callback(nil)
      return
    end

    local issue = choice.issue
    if issue == nil then
      callback({ manual = true })
    else
      callback({
        manual = false,
        key = issue.key,
        summary = issue.summary or "",
        raw = issue.raw,
      })
    end
  end)
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

  show_repo_selection(label, task_dir, task_dir_name)
end

local function prompt_suffix(issue_key, default_suffix)
  local Snacks = require("snacks")

  Snacks.input({
    prompt = "Branch suffix (optional)",
    default = default_suffix or "",
  }, function(value)
    if value == nil then
      return
    end
    local suffix = slugify(value)
    finalize_task(issue_key, suffix)
  end)
end

local function prompt_manual_issue(default_issue, default_suffix)
  local Snacks = require("snacks")

  Snacks.input({
    prompt = "Issue key (e.g. DEP-123)",
    default = default_issue or "",
  }, function(value)
    if value == nil then
      return
    end

    local issue_key, inline_suffix = parse_issue_string(value, M.config.jira_prefix)
    if not issue_key then
      vim.notify("Issue key is required", vim.log.levels.ERROR)
      prompt_manual_issue(default_issue, default_suffix)
      return
    end

    local suffix_hint = inline_suffix ~= "" and inline_suffix or (default_suffix or "")
    prompt_suffix(issue_key, suffix_hint)
  end)
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

  pick_issue(function(selection)
    if not selection then
      return
    end

    if selection.manual then
      prompt_manual_issue(nil, nil)
      return
    end

    local issue_key = selection.key
    if not issue_key or issue_key == "" then
      vim.notify("Selected Jira issue is missing a key", vim.log.levels.ERROR)
      return
    end

    local suffix_hint = slugify(selection.summary or "")
    prompt_suffix(issue_key:upper(), suffix_hint)
  end)
end


-- Add another repo to an existing task
function M.add_repo_to_task()
  local cwd = vim.fn.getcwd()
  local task_dir = resolve_task_dir(cwd)

  -- Check if we're in a task directory
  if not task_dir then
    vim.notify("Not in a task directory. Run :JiraTask first", vim.log.levels.ERROR)
    return
  end

  local task_id = vim.fn.fnamemodify(task_dir, ":t")
  -- Get available repos
  local repos = M.get_available_repos()
  if #repos == 0 then
    vim.notify("No bare repos found in " .. M.config.repos_base, vim.log.levels.WARN)
    return
  end

  -- Show TUI menu to select repository
  local Menu = require("nui.menu")

  local menu_items = {}
  for _, repo in ipairs(repos) do
    -- Check if already exists
    if vim.fn.isdirectory(task_dir .. "/" .. repo.name) == 1 then
      table.insert(menu_items, Menu.item("✓ " .. repo.name .. " (already added)", { repo = repo, exists = true }))
    else
      table.insert(menu_items, Menu.item("📦 " .. repo.name, { repo = repo, exists = false }))
    end
  end

  local menu = Menu({
    position = "50%",
    size = {
      width = 50,
      height = math.min(#menu_items + 2, 15),
    },
    border = {
      style = "rounded",
      text = {
        top = " Add Repository to " .. task_id:upper() .. " ",
        top_align = "center",
      },
    },
  }, {
    lines = menu_items,
    max_width = 48,
    keymap = {
      focus_next = { "j", "<Down>", "<Tab>" },
      focus_prev = { "k", "<Up>", "<S-Tab>" },
      close = { "<Esc>", "<C-c>", "q" },
      submit = { "<CR>", "<Space>" },
    },
    on_submit = function(item)
      if item.exists then
        vim.notify("Repository already added to this task", vim.log.levels.WARN)
        return
      end

      local selected_repo = item.repo
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

  menu:mount()
end

-- List all tasks with Telescope
function M.list_tasks()
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

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

  pickers.new({}, {
    prompt_title = "Jira Tasks",
    finder = finders.new_table({
      results = entries,
      entry_maker = function(entry)
        return {
          value = entry,
          display = entry.display,
          ordinal = entry.ordinal,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      local function delete_selected_task()
        local selection = action_state.get_selected_entry()
        if not selection or selection.value.kind ~= "task" then
          vim.notify("Select a task before deleting", vim.log.levels.WARN)
          return
        end
        actions.close(prompt_bufnr)
        M.prompt_delete_task(selection.value.task)
      end

      map("i", "<C-d>", delete_selected_task)
      map("n", "d", delete_selected_task)

      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if not selection then
          return
        end

        local entry = selection.value

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
      end)
      return true
    end,
  }):find()
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

  pickers.new({}, {
    prompt_title = "Task Repositories",
    finder = finders.new_table({
      results = repos,
      entry_maker = function(entry)
        return {
          value = entry,
          display = entry.name,
          ordinal = entry.name,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if selection then
          -- Change to repo directory
          vim.cmd("cd " .. vim.fn.fnameescape(selection.value.path))
          vim.notify("Switched to repo: " .. selection.value.name, vim.log.levels.INFO)
          restore_auto_session()
          M.reveal_path_in_tree(selection.value.path)
        end
      end)
      return true
    end,
  }):find()
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
    local ok, message = prune_repo_worktrees(repo, { silent = true })
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
          local code, output = run_git(repo.path, { "worktree", "remove", "--force", worktree_path })
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
