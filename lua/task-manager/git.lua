local M = {}

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

function M.run_git(bare_repo, args)
  local cmd = { "git", "--git-dir=" .. bare_repo }
  vim.list_extend(cmd, args)
  return run_command(cmd)
end

function M.command(args)
  return run_command(args)
end

function M.get_repo_branch(path)
  local code, output = run_command({ "git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD" })
  if code ~= 0 then
    return nil
  end
  if output == "HEAD" then
    local _, commit = run_command({ "git", "-C", path, "rev-parse", "--short", "HEAD" })
    return commit ~= "" and ("detached@" .. commit) or "detached"
  end
  return output
end

function M.prune_worktrees(repo, opts)
  opts = opts or {}
  local code, output = M.run_git(repo.path, { "worktree", "prune", "--expire=now" })
  if code ~= 0 then
    local message = output ~= "" and output or "git worktree prune failed"
    if not opts.silent then
      vim.notify("Failed to prune worktrees for " .. repo.name .. ": " .. message, vim.log.levels.ERROR)
    end
    return false, message
  end
  return true
end

function M.get_upstream_branch(path)
  local code, output = run_command({ "git", "-C", path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" })
  if code ~= 0 or output == "" then
    return nil
  end
  return output
end

function M.get_remote_url(path, remote)
  remote = remote or "origin"
  local code, output = run_command({ "git", "-C", path, "remote", "get-url", remote })
  if code ~= 0 or output == "" then
    return nil
  end
  return output
end

local function parse_github_repo(url)
  if not url then
    return nil
  end
  local repo = url:match("github%.com[:/](.+)$")
  if not repo then
    return nil
  end
  repo = repo:gsub("%.git$", "")
  return repo
end

function M.get_remote_repo(path, remote)
  local url = M.get_remote_url(path, remote)
  if not url then
    return nil
  end
  return parse_github_repo(url)
end

return M
