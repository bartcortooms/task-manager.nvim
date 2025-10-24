local git = require("task-manager.git")

local M = {}

function M.normalize_path(path)
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

function M.normalize_and_compare(a, b)
  local na = M.normalize_path(a)
  local nb = M.normalize_path(b)
  if not na or not nb then
    return false
  end
  return na == nb
end

function M.slugify(str)
  str = str or ""
  str = str:lower()
  str = str:gsub("%s+", "-")
  str = str:gsub("[^%w%-]", "-")
  str = str:gsub("%-+", "-")
  str = str:gsub("^%-", "")
  str = str:gsub("%-$", "")
  return str
end

function M.build_task_name(issue_key, suffix)
  if suffix and suffix ~= "" then
    return string.format("%s-%s", issue_key:lower(), M.slugify(suffix))
  end
  return issue_key:lower()
end

function M.parse_issue_string(value, jira_prefix)
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
    suffix = M.slugify(extra)
  end

  return issue_key, suffix
end

function M.resolve_task_dir(path, tasks_base)
  local base = M.normalize_path(tasks_base)
  local target = M.normalize_path(path or vim.fn.getcwd())
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

function M.is_path_inside(path, root)
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

function M.get_task_repos(task_dir)
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
          branch = git.get_repo_branch(path),
        })
      end
    end
  end

  table.sort(repos, function(a, b)
    return a.name < b.name
  end)

  return repos
end

function M.get_tasks(tasks_base)
  local tasks = {}
  local handle = vim.loop.fs_scandir(tasks_base)
  if handle then
    while true do
      local name, type = vim.loop.fs_scandir_next(handle)
      if not name then
        break
      end
      if type == "directory" then
        table.insert(tasks, {
          name = name,
          path = tasks_base .. "/" .. name,
        })
      end
    end
  end

  table.sort(tasks, function(a, b)
    return a.name < b.name
  end)

  return tasks
end

function M.resolve_task_identifier(task, tasks_base)
  if type(task) == "table" and task.name and task.path then
    return task.name, task.path
  end

  if type(task) == "string" and task ~= "" then
    local normalized = task:lower()
    local path = tasks_base .. "/" .. normalized
    return normalized, path
  end

  return nil, nil
end

return M
