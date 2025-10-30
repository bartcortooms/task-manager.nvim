local config = require("task-manager.config")
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

local M = {}

local function current_config()
  return config.get()
end

local function restore_auto_session()
  local ok, auto_session = pcall(require, "auto-session")
  if not ok then
    return
  end

  pcall(auto_session.restore_session, nil, { show_message = false })
end

local function get_tasks()
  local cfg = current_config()
  return task_utils.get_tasks(cfg.tasks_base)
end

local function resolve_task_identifier(task)
  local cfg = current_config()
  return task_utils.resolve_task_identifier(task, cfg.tasks_base)
end

local function resolve_task_dir(path)
  local cfg = current_config()
  return task_utils.resolve_task_dir(path, cfg.tasks_base)
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
  local cfg = current_config()
  local current = normalize_path(path)
  if not current then
    return nil
  end

  if vim.fn.isdirectory(current) == 0 then
    current = vim.fn.fnamemodify(current, ":h")
  end

  while current and current ~= "" and current ~= cfg.tasks_base and current ~= "/" do
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

local function ensure_issue_description_file(task_dir, issue)
  local description_file = task_dir .. "/issue-description.md"
  if vim.fn.filereadable(description_file) == 1 then
    return true
  end

  if not issue or not issue.description or issue.description == "" then
    return false
  end

  local header_parts = {}
  if issue.key and issue.key ~= "" then
    table.insert(header_parts, issue.key)
  end
  if issue.summary and issue.summary ~= "" then
    table.insert(header_parts, issue.summary)
  end

  local lines = {}
  if #header_parts > 0 then
    table.insert(lines, "# " .. table.concat(header_parts, ": "))
    table.insert(lines, "")
  end

  vim.list_extend(lines, vim.split(issue.description, "\n", { plain = true }))

  local ok, err = pcall(vim.fn.writefile, lines, description_file)
  if not ok then
    vim.notify("Failed to write Jira description: " .. tostring(err), vim.log.levels.WARN)
    return false
  end

  return true
end

local function get_worktree_path(task_dir, worktree_name)
  return task_dir .. "/" .. worktree_name
end

local function worktree_exists(task_dir, worktree_name)
  return vim.fn.isdirectory(get_worktree_path(task_dir, worktree_name)) == 1
end

local function after_worktree_created(task_dir, worktree_name)
  local worktree_path = get_worktree_path(task_dir, worktree_name)
  vim.cmd("cd " .. vim.fn.fnameescape(worktree_path))
  restore_auto_session()
  M.reveal_path_in_tree(worktree_path)
end

function M.create_repo_worktree(task_dir, repo_obj, branch_name, opts)
  return worktree.create(task_dir, repo_obj, branch_name, opts)
end

local function add_repo_worktree(task_dir, repo, branch_base, opts)
  opts = opts or {}
  local message_prefix = opts.message_prefix or "Added worktree"

  local function create_and_setup(worktree_name, branch_name)
    local ok = M.create_repo_worktree(task_dir, repo, branch_name, { worktree_name = worktree_name })
    if not ok then
      return
    end
    vim.notify(string.format("%s: %s (%s)", message_prefix, worktree_name, branch_name), vim.log.levels.INFO)
    after_worktree_created(task_dir, worktree_name)
    if opts.on_success then
      opts.on_success(worktree_name, branch_name)
    end
  end

  if not worktree_exists(task_dir, repo.name) then
    create_and_setup(repo.name, branch_base)
    return
  end

  local function prompt_for_suffix()
    ui.prompt_suffix({
      prompt = (opts.suffix_prompt and opts.suffix_prompt(repo))
        or ("Suffix for " .. repo.name .. " (required for additional worktree)"),
      default_suffix = opts.default_suffix or "",
      on_cancel = function()
        if opts.on_cancel then
          opts.on_cancel()
        end
      end,
      on_submit = function(suffix)
        if suffix == "" then
          vim.notify("Suffix is required to create another worktree for " .. repo.name, vim.log.levels.ERROR)
          prompt_for_suffix()
          return
        end
        local worktree_name = repo.name .. "-" .. suffix
        if worktree_exists(task_dir, worktree_name) then
          vim.notify("Worktree '" .. worktree_name .. "' already exists in this task", vim.log.levels.ERROR)
          prompt_for_suffix()
          return
        end
        local branch_name = branch_base .. "-" .. suffix
        create_and_setup(worktree_name, branch_name)
      end,
    })
  end

  prompt_for_suffix()
end

local function present_repo_menu(opts)
  opts = opts or {}
  local repos = opts.repos or M.get_available_repos()

  ui.show_repo_menu({
    repos = repos,
    task_label = opts.task_label,
    task_dir = opts.task_dir,
    on_empty = opts.on_empty,
    on_select = function(selected_repo)
      add_repo_worktree(opts.task_dir, selected_repo, opts.branch_base, {
        message_prefix = opts.message_prefix,
        suffix_prompt = opts.suffix_prompt,
        default_suffix = opts.default_suffix,
        on_cancel = opts.on_cancel,
        on_success = opts.on_success,
      })
    end,
    on_exists = function(selected_repo)
      add_repo_worktree(opts.task_dir, selected_repo, opts.branch_base, {
        message_prefix = opts.message_prefix,
        suffix_prompt = opts.suffix_prompt,
        default_suffix = opts.default_suffix,
        on_cancel = opts.on_cancel,
        on_success = opts.on_success,
      })
    end,
  })
end

local function finalize_task(issue_key, suffix, issue_details)
  local cfg = current_config()
  local task_dir_name = build_task_name(issue_key, suffix or "")
  local task_dir = cfg.tasks_base .. "/" .. task_dir_name

  if vim.fn.isdirectory(task_dir) == 0 then
    vim.fn.mkdir(task_dir, "p")
    vim.notify("Created task directory: " .. task_dir, vim.log.levels.INFO)
  end

  local has_description_file = ensure_issue_description_file(task_dir, issue_details)
  if not has_description_file and jira.is_enabled and jira.is_enabled() then
    local issue, err = jira.fetch_issue(issue_key)
    if issue then
      if issue.description and issue.description ~= "" then
        ensure_issue_description_file(task_dir, issue)
      else
        vim.notify("No Jira description available for " .. issue_key, vim.log.levels.INFO)
      end
    elseif err and err ~= "" then
      vim.notify(err, vim.log.levels.WARN)
    end
  end

  local label = issue_key
  if suffix and suffix ~= "" then
    label = label .. " · " .. suffix
  end

  present_repo_menu({
    task_dir = task_dir,
    task_label = label,
    branch_base = task_dir_name,
    message_prefix = "Created worktree",
    suffix_prompt = function(repo)
      return "Suffix for " .. repo.name .. " (required for additional worktree)"
    end,
    on_empty = function()
      local cfg_inner = current_config()
      vim.notify("No bare repos found in " .. cfg_inner.repos_base, vim.log.levels.WARN)
      vim.notify("Task directory created, but no worktrees added", vim.log.levels.INFO)
      vim.cmd("cd " .. vim.fn.fnameescape(task_dir))
    end,
  })
end

local function prompt_suffix(issue_key, default_suffix, issue_details)
  ui.prompt_suffix({
    default_suffix = default_suffix or "",
    on_submit = function(suffix)
      finalize_task(issue_key, suffix, issue_details)
    end,
  })
end

local function prompt_manual_issue(default_issue, default_suffix)
  ui.prompt_issue_key({
    default_issue = default_issue,
    jira_prefix = current_config().jira_prefix,
    parse_issue_string = parse_issue_string,
    on_invalid = function()
      vim.notify("Issue key is required", vim.log.levels.ERROR)
      prompt_manual_issue(default_issue, default_suffix)
    end,
    on_submit = function(issue_key, inline_suffix)
      local suffix_hint = inline_suffix ~= "" and inline_suffix or (default_suffix or "")
      prompt_suffix(issue_key, suffix_hint, nil)
    end,
  })
end

function M.get_available_repos()
  local cfg = current_config()
  local repos = {}
  local handle = vim.loop.fs_scandir(cfg.repos_base)
  if handle then
    while true do
      local name, type = vim.loop.fs_scandir_next(handle)
      if not name then
        break
      end

      local bare_path = cfg.repos_base .. "/" .. name
      local head_file = bare_path .. "/HEAD"
      local refs_dir = bare_path .. "/refs"
      if type == "directory" and vim.fn.filereadable(head_file) == 1 and vim.fn.isdirectory(refs_dir) == 1 then
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

function M.reveal_path_in_tree(path)
  if not path or path == "" then
    return
  end

  local cfg = current_config()
  local normalized = normalize_path(path)
  if not normalized then
    return
  end

  if not is_path_inside(normalized, cfg.tasks_base) then
    return
  end

  local command = load_neotree_command()
  if not command then
    return
  end

  local repo_root = resolve_repo_root(normalized)
  local tree_root = repo_root or resolve_task_dir(normalized) or normalize_path(cfg.tasks_base)

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

function M.is_tasks_base(dir)
  local cfg = current_config()
  return normalize_and_compare(dir or vim.fn.getcwd(), cfg.tasks_base)
end

function M.is_in_tasks_tree(dir)
  local cfg = current_config()
  local base = normalize_path(cfg.tasks_base)
  local target = normalize_path(dir or vim.fn.getcwd())
  if not base or base == "" or not target then
    return false
  end
  if target == base then
    return true
  end
  return target:sub(1, #base + 1) == base .. "/"
end

function M.create_task(issue_number)
  local cfg = current_config()

  if issue_number and issue_number ~= "" then
    local issue_key, suffix = parse_issue_string(issue_number, cfg.jira_prefix)
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
      local level = (jira.is_enabled and jira.is_enabled()) and vim.log.levels.ERROR or vim.log.levels.INFO
      vim.notify(fetch_err, level)
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
      local issue_details = {
        key = issue_key:upper(),
        summary = issue.summary,
        description = issue.description,
      }
      prompt_suffix(issue_details.key, suffix_hint, issue_details)
    end,
  })
end

function M.add_repo_to_task()
  local cwd = vim.fn.getcwd()
  local task_dir = resolve_task_dir(cwd)

  if not task_dir then
    vim.notify("Not in a task directory. Run :JiraTask first", vim.log.levels.ERROR)
    return
  end

  local task_id = vim.fn.fnamemodify(task_dir, ":t")

  present_repo_menu({
    task_dir = task_dir,
    task_label = task_id:upper(),
    branch_base = task_id,
    message_prefix = "Added worktree",
    suffix_prompt = function(repo)
      return "Suffix for " .. repo.name .. " (required for additional worktree)"
    end,
    on_empty = function()
      local cfg_inner = current_config()
      vim.notify("No bare repos found in " .. cfg_inner.repos_base, vim.log.levels.WARN)
    end,
  })
end

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

function M.list_task_repos()
  local cwd = vim.fn.getcwd()
  local task_dir = resolve_task_dir(cwd)
  if not task_dir then
    vim.notify("Not in a task directory", vim.log.levels.ERROR)
    return
  end

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
  local cfg = current_config()
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
    vim.cmd("cd " .. vim.fn.fnameescape(cfg.tasks_base))
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

return M
