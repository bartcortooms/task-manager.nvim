local M = {
  config = nil,
}

local function resolve_value(value, field_name)
  if type(value) == "function" then
    local ok, result = pcall(value)
    if not ok then
      error(string.format("Task Manager: failed to evaluate jira.%s: %s", field_name, result))
    end
    value = result
  end

  if value == nil then
    return nil
  end

  if type(value) == "string" then
    value = vim.trim(value)
    if value == "" then
      return nil
    end
  end

  return value
end

local function normalize_domain(url)
  if not url then
    return nil
  end

  url = vim.trim(url)
  if url == "" then
    return nil
  end

  url = url:gsub("^https?://", "")
  url = url:gsub("/+$", "")

  if url == "" then
    return nil
  end

  return url
end

local function resolve_config(config, defaults)
  config = config or {}
  defaults = defaults or {}

  local resolved = {
    url = normalize_domain(resolve_value(config.url, "url")),
    email = resolve_value(config.email, "email"),
    api_token = resolve_value(config.api_token, "api_token"),
    jql = resolve_value(config.jql, "jql") or defaults.jql or "",
    max_results = tonumber(resolve_value(config.max_results, "max_results") or defaults.max_results or config.max_results) or defaults.max_results or 50,
  }

  if not resolved.url then
    error("Task Manager: configure jira.url via require('task-manager').setup({ jira = { url = ... } })")
  end
  if not resolved.email then
    error("Task Manager: configure jira.email via require('task-manager').setup({ jira = { email = ... } })")
  end
  if not resolved.api_token then
    error("Task Manager: configure jira.api_token via require('task-manager').setup({ jira = { api_token = ... } })")
  end
  if resolved.max_results <= 0 then
    error("Task Manager: jira.max_results must be greater than zero")
  end

  return resolved
end

function M.setup(config, defaults)
  local resolved = resolve_config(config, defaults)

  local ok_lazy, lazy = pcall(require, "lazy")
  if ok_lazy then
    pcall(lazy.load, { plugins = { "jirac.nvim" } })
  end

  local ok, jirac = pcall(require, "jirac")
  if not ok then
    error("Task Manager: jirac.nvim is not available. Please add janBorowy/jirac.nvim to your plugin list.")
  end

  jirac.setup({
    api_key = resolved.api_token,
    email = resolved.email,
    jira_domain = resolved.url,
  })

  M.config = resolved
  return resolved
end

function M.fetch_assigned_issues()
  if not M.config then
    return nil, "Task Manager: Jira integration has not been configured"
  end

  local ok_service, jira_service = pcall(require, "jirac.jira_service")
  if not ok_service then
    return nil, "Task Manager: failed to load jirac.jira_service: " .. jira_service
  end

  local ok_executor, request_executor = pcall(require, "jirac.request_executor")
  if not ok_executor then
    return nil, "Task Manager: failed to load jirac.request_executor: " .. request_executor
  end

  local ok_search, result = pcall(request_executor.wrap_get_request, {
    url = jira_service.get_jira_url("search", "jql"),
    response_mapper = function(data)
      if type(data) == "table" and type(data.issues) == "table" then
        return data.issues
      end
      return {}
    end,
    curl_opts = vim.tbl_extend("force", jira_service.get_base_opts(), {
      query = {
        jql = M.config.jql,
        maxResults = M.config.max_results,
        fields = "key,summary",
      },
    }),
  })

  if not ok_search then
    return nil, "Task Manager: Jira search failed - " .. result
  end

  local issues = {}
  if type(result) ~= "table" then
    return nil, "Task Manager: Unexpected Jira response format"
  end

  for _, raw_issue in ipairs(result) do
    if type(raw_issue) == "table" then
      local key = raw_issue.key
      local summary = raw_issue.summary or (raw_issue.fields and raw_issue.fields.summary) or ""
      if key then
        table.insert(issues, {
          key = key,
          summary = summary,
          raw = raw_issue,
        })
      end
    end
  end

  return issues
end

M.resolve_config = resolve_config

return M
