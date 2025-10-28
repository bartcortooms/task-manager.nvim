local M = {
  config = nil,
  _enabled = false,
  _disabled_reason = nil,
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

local function load_dependencies()
  local ok_service, jira_service = pcall(require, "jirac.jira_service")
  if not ok_service then
    return nil, "Task Manager: failed to load jirac.jira_service: " .. jira_service
  end

  local ok_executor, request_executor = pcall(require, "jirac.request_executor")
  if not ok_executor then
    return nil, "Task Manager: failed to load jirac.request_executor: " .. request_executor
  end

  local adf_utils
  local ok_adf_utils, mod = pcall(require, "jirac.adf_utils")
  if ok_adf_utils then
    adf_utils = mod
  end

  return {
    jira_service = jira_service,
    request_executor = request_executor,
    adf_utils = adf_utils,
  }
end

local function flatten_adf_node(node, chunks)
  if type(node) ~= "table" then
    return
  end

  if node.type == "text" then
    table.insert(chunks, node.text or "")
  elseif node.type == "hardBreak" then
    table.insert(chunks, "\n")
  end

  if type(node.content) == "table" then
    for _, child in ipairs(node.content) do
      flatten_adf_node(child, chunks)
    end
  end
end

local function adf_to_plain_text(doc)
  if type(doc) ~= "table" then
    return nil
  end

  local chunks = {}
  flatten_adf_node(doc, chunks)

  local text = table.concat(chunks)
  text = vim.trim(text)
  if text ~= "" then
    return text
  end

  return nil
end

local function extract_description(raw_description, adf_utils)
  if not raw_description or raw_description == vim.NIL then
    return nil
  end

  if adf_utils and type(raw_description) == "table" then
    local ok_parse, parsed = pcall(adf_utils.parse, raw_description)
    if ok_parse then
      local trimmed = vim.trim(parsed or "")
      if trimmed ~= "" then
        return trimmed
      end
    end
    local fallback = adf_to_plain_text(raw_description)
    if fallback then
      return fallback
    end
  elseif type(raw_description) == "table" then
    local fallback = adf_to_plain_text(raw_description)
    if fallback then
      return fallback
    end
  elseif type(raw_description) == "string" then
    local trimmed = vim.trim(raw_description)
    if trimmed ~= "" then
      return trimmed
    end
  end

  return nil
end

local DONE_STATUS_NAMES = {
  done = true,
  resolved = true,
  closed = true,
  canceled = true,
  cancelled = true,
}

local function is_actionable_status(status)
  if type(status) ~= "table" then
    return true
  end

  local category = status.statusCategory
  if type(category) == "table" then
    local category_key = type(category.key) == "string" and category.key:lower() or nil
    local category_name = type(category.name) == "string" and category.name:lower() or nil
    if category_key == "done" or category_name == "done" then
      return false
    end
  end

  local name = type(status.name) == "string" and status.name:lower() or nil
  if name and DONE_STATUS_NAMES[name] then
    return false
  end

  return true
end

function M.setup(config, defaults)
  local ok_lazy, lazy = pcall(require, "lazy")
  if ok_lazy then
    pcall(lazy.load, { plugins = { "jirac.nvim" } })
  end

  local ok, jirac = pcall(require, "jirac")
  if not ok then
    M.config = nil
    M._enabled = false
    M._disabled_reason = "Task Manager: Jira integration disabled (jirac.nvim not available)"
    return nil
  end

  local resolved = resolve_config(config, defaults)

  jirac.setup({
    api_key = resolved.api_token,
    email = resolved.email,
    jira_domain = resolved.url,
  })

  M.config = resolved
  M._enabled = true
  M._disabled_reason = nil

  return resolved
end

function M.fetch_assigned_issues()
  if not M._enabled or not M.config then
    return nil, M._disabled_reason or "Task Manager: Jira integration has not been configured"
  end

  local deps, dep_err = load_dependencies()
  if not deps then
    return nil, dep_err
  end

  local ok_search, result = pcall(deps.request_executor.wrap_get_request, {
    url = deps.jira_service.get_jira_url("search", "jql"),
    response_mapper = function(data)
      if type(data) == "table" and type(data.issues) == "table" then
        return data.issues
      end
      return {}
    end,
    curl_opts = vim.tbl_extend("force", deps.jira_service.get_base_opts(), {
      query = {
        jql = M.config.jql,
        maxResults = M.config.max_results,
        fields = "summary,description,status",
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
      local fields = raw_issue.fields or {}
      local summary = raw_issue.summary or fields.summary or ""
      local raw_description = raw_issue.description or fields.description
      local status = raw_issue.status or fields.status

      if is_actionable_status(status) then
        local description = extract_description(raw_description, deps.adf_utils)

        if key then
          table.insert(issues, {
            key = key,
            summary = summary,
            description = description,
            status = status and status.name,
            raw = raw_issue,
          })
        end
      end
    end
  end

  return issues
end

function M.fetch_issue(issue_key)
  if not issue_key or issue_key == "" then
    return nil, "Task Manager: Issue key is required"
  end

  if not M._enabled or not M.config then
    return nil, M._disabled_reason or "Task Manager: Jira integration has not been configured"
  end

  local trimmed_key = vim.trim(issue_key)
  if trimmed_key == "" then
    return nil, "Task Manager: Issue key is required"
  end

  local deps, dep_err = load_dependencies()
  if not deps then
    return nil, dep_err
  end

  local ok_fetch, result = pcall(deps.request_executor.wrap_get_request, {
    url = deps.jira_service.get_jira_url("issue", trimmed_key),
    response_mapper = function(data)
      return data
    end,
    curl_opts = vim.tbl_extend("force", deps.jira_service.get_base_opts(), {
      query = {
        fields = "summary,description",
      },
    }),
  })

  if not ok_fetch then
    return nil, "Task Manager: Jira issue fetch failed - " .. result
  end

  if type(result) ~= "table" then
    return nil, "Task Manager: Unexpected Jira issue response format"
  end

  local fields = result.fields or {}
  local summary = result.summary or fields.summary or ""
  local description = extract_description(fields.description or result.description, deps.adf_utils)

  return {
    key = result.key or trimmed_key,
    summary = summary,
    description = description,
    raw = result,
  }
end

M.resolve_config = resolve_config
M.is_enabled = function()
  return M._enabled
end

M.disabled_reason = function()
  return M._disabled_reason
end

return M
