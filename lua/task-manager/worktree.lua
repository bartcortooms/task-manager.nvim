local git = require("task-manager.git")

local M = {}

local function notify_and_return(message, level)
  vim.notify(message, level or vim.log.levels.ERROR)
  return false, message
end

local function parse_worktree_list(output)
  local current = { branch = nil, prunable = false, path = nil }
  local entries = {}

  for line in string.gmatch((output or "") .. "\n", "([^\n]*)\n") do
    if line == "" then
      if current.branch then
        entries[#entries + 1] = current
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

  return entries
end

local function ensure_branch_available(bare_repo, repo_name, branch_name)
  local branch_exists = false
  local branch_code, branch_output = git.run_git(bare_repo, { "rev-parse", "--verify", "--quiet", branch_name })
  if branch_code == 0 then
    branch_exists = true
  elseif branch_code ~= 1 then
    return notify_and_return(
      "Failed to inspect branch: " .. (branch_output ~= "" and branch_output or "git rev-parse failed")
    )
  end

  if not branch_exists then
    return true, false
  end

  local list_code, list_output = git.run_git(bare_repo, { "worktree", "list", "--porcelain" })
  if list_code ~= 0 then
    return notify_and_return(
      "Failed to inspect existing worktrees: " .. (list_output ~= "" and list_output or "git worktree list failed")
    )
  end

  local entries = parse_worktree_list(list_output)

  for _, entry in ipairs(entries) do
    local branch = entry.branch and entry.branch:gsub("^refs/heads/", "")
    if branch == branch_name and not entry.prunable then
      return notify_and_return("Branch '" .. branch_name .. "' already checked out in another worktree")
    end
  end

  for _, entry in ipairs(entries) do
    local branch = entry.branch and entry.branch:gsub("^refs/heads/", "")
    if branch == branch_name and entry.prunable then
      if entry.path then
        local remove_code, remove_output =
          git.run_git(bare_repo, { "worktree", "remove", "--force", entry.path })
        if remove_code ~= 0 then
          return notify_and_return(
            "Failed to remove stale worktree at "
              .. entry.path
              .. ": "
              .. (remove_output ~= "" and remove_output or "git worktree remove failed")
          )
        end
      end

      local pruned_ok, prune_err = git.prune_worktrees({ name = repo_name, path = bare_repo }, { silent = true })
      if not pruned_ok then
        return notify_and_return(
          "Failed to prune worktrees for "
            .. repo_name
            .. ": "
            .. (prune_err or "git worktree prune failed")
        )
      end

      local recheck_code, recheck_output = git.run_git(bare_repo, { "worktree", "list", "--porcelain" })
      if recheck_code == 0 then
        for _, re_entry in ipairs(parse_worktree_list(recheck_output)) do
          local ref = re_entry.branch and re_entry.branch:gsub("^refs/heads/", "")
          if ref == branch_name then
            return notify_and_return(
              "Branch '" .. branch_name .. "' still appears in worktree list after cleanup"
            )
          end
        end
      end
      break
    end
  end

  return true, true
end

function M.create(task_dir, repo_obj, branch_name)
  local bare_repo = repo_obj.path
  local repo_name = repo_obj.name

  if vim.fn.isdirectory(bare_repo) == 0 then
    return notify_and_return("Bare repo not found: " .. bare_repo)
  end

  local worktree_path = task_dir .. "/" .. repo_name
  if vim.fn.isdirectory(worktree_path) == 1 then
    return notify_and_return("Worktree directory already exists: " .. worktree_path, vim.log.levels.WARN)
  end

  local ok, branch_exists = ensure_branch_available(bare_repo, repo_name, branch_name)
  if not ok then
    return false
  end

  local args
  if branch_exists then
    args = { "worktree", "add", worktree_path, branch_name }
  else
    args = { "worktree", "add", worktree_path, "-b", branch_name }
  end

  local code, output = git.run_git(bare_repo, args)
  if code ~= 0 then
    return notify_and_return("Failed to create worktree: " .. (output ~= "" and output or "git worktree add failed"))
  end

  return true
end

return M
