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

local function apply_marks_to_text(text, marks)
  if type(marks) ~= "table" then
    return text
  end

  local link_href
  for _, mark in ipairs(marks) do
    if mark and mark.type == "link" and mark.attrs and mark.attrs.href then
      link_href = mark.attrs.href
    end
  end

  for _, mark in ipairs(marks) do
    if not mark or not mark.type then
      goto continue
    end

    local t = mark.type
    if t == "strong" then
      text = string.format("**%s**", text)
    elseif t == "em" then
      text = string.format("*%s*", text)
    elseif t == "strike" then
      text = string.format("~~%s~~", text)
    elseif t == "code" then
      local fence = "`"
      if text:find("`", 1, true) then
        local backtick_count = select(2, text:gsub("`", "")) + 1
        fence = string.rep("`", backtick_count)
      end
      text = string.format("%s%s%s", fence, text, fence)
    elseif t == "underline" then
      text = string.format("<u>%s</u>", text)
    elseif t == "subsup" and mark.attrs then
      if mark.attrs.type == "sub" then
        text = string.format("~%s~", text)
      elseif mark.attrs.type == "sup" then
        text = string.format("^%s^", text)
      end
    end

    ::continue::
  end

  if link_href then
    local display = text ~= "" and text or link_href
    text = string.format("[%s](%s)", display, link_href)
  end

  return text
end

local function render_inline_node(node)
  if type(node) ~= "table" then
    return ""
  end

  if node.type == "text" then
    local text = node.text or ""
    return apply_marks_to_text(text, node.marks)
  elseif node.type == "hardBreak" then
    return "  \n"
  elseif node.type == "emoji" then
    local attrs = node.attrs or {}
    return attrs.text or attrs.emoji or attrs.shortName or attrs.fallback or ""
  elseif node.type == "mention" then
    local attrs = node.attrs or {}
    if attrs.text and attrs.text ~= "" then
      return attrs.text
    elseif attrs.userId and attrs.userId ~= "" then
      return "@" .. attrs.userId
    end
    return ""
  elseif node.type == "inlineCard" then
    local attrs = node.attrs or {}
    return attrs.url or attrs.title or ""
  elseif node.type == "status" then
    local attrs = node.attrs or {}
    local label = attrs.text or ""
    if attrs.color and attrs.color ~= "" then
      if label ~= "" then
        label = string.format("[%s] %s", attrs.color, label)
      else
        label = attrs.color
      end
    end
    if label ~= "" then
      return string.format("`%s`", label)
    end
    return ""
  end

  return ""
end

local function render_inline_nodes(nodes)
  if type(nodes) ~= "table" then
    return ""
  end

  local parts = {}
  for _, child in ipairs(nodes) do
    local rendered = render_inline_node(child)
    if rendered and rendered ~= "" then
      table.insert(parts, rendered)
    end
  end

  return table.concat(parts)
end

local render_block_node

local function render_nodes(nodes, ctx)
  if type(nodes) ~= "table" then
    return {}
  end

  local lines = {}
  local tight = ctx and ctx.tight

  for _, child in ipairs(nodes) do
    local block_lines, opts = render_block_node(child, ctx)
    if #block_lines > 0 then
      local suppress_spacing = tight or (opts and opts.suppress_spacing)
      if #lines > 0 and lines[#lines] ~= "" and block_lines[1] ~= "" and not suppress_spacing then
        table.insert(lines, "")
      end
      vim.list_extend(lines, block_lines)
    end
  end

  return lines
end

local function render_table(node, ctx)
  local rows = {}
  for _, row in ipairs(node.content or {}) do
    local cells = {}
    for _, cell in ipairs(row.content or {}) do
      local cell_ctx = { list_depth = 0, tight = true }
      local cell_lines = render_nodes(cell.content or {}, cell_ctx)
      local cell_text = table.concat(cell_lines, " ")
      cell_text = cell_text:gsub("%s+", " ")
      table.insert(cells, vim.trim(cell_text))
    end
    table.insert(rows, cells)
  end

  if #rows == 0 then
    return {}
  end

  local column_count = 0
  for _, cells in ipairs(rows) do
    if #cells > column_count then
      column_count = #cells
    end
  end

  if column_count == 0 then
    return {}
  end

  local function format_row(cells)
    local padded = {}
    for i = 1, column_count do
      padded[i] = vim.trim(cells[i] or "")
    end
    return "| " .. table.concat(padded, " | ") .. " |"
  end

  local lines = {}
  table.insert(lines, format_row(rows[1]))

  local separators = {}
  for i = 1, column_count do
    separators[i] = "---"
  end
  table.insert(lines, "| " .. table.concat(separators, " | ") .. " |")

  for i = 2, #rows do
    table.insert(lines, format_row(rows[i]))
  end

  return lines
end

local function render_blockquote(node, ctx)
  local inner_lines = render_nodes(node.content or {}, { list_depth = ctx and ctx.list_depth or 0, tight = false })
  if #inner_lines == 0 then
    return {">"}
  end

  for index, line in ipairs(inner_lines) do
    if line ~= "" then
      inner_lines[index] = "> " .. line
    else
      inner_lines[index] = ">"
    end
  end

  return inner_lines
end

local function render_code_block(node)
  local language = ""
  if node.attrs and node.attrs.language then
    language = node.attrs.language
  end

  local chunks = {}
  for _, child in ipairs(node.content or {}) do
    if child.type == "text" then
      table.insert(chunks, child.text or "")
    elseif child.type == "hardBreak" then
      table.insert(chunks, "\n")
    end
  end

  local code = table.concat(chunks):gsub("\r\n", "\n")
  local code_lines = vim.split(code, "\n", { plain = true })

  local lines = { string.format("```%s", language or "") }
  for _, line in ipairs(code_lines) do
    table.insert(lines, line)
  end
  table.insert(lines, "```")

  return lines
end

local function render_list_item(item, ctx, list_kind, counter)
  local depth = (ctx and ctx.list_depth or 0) + 1
  local child_ctx = { list_depth = depth, tight = true }
  local content_lines = render_nodes(item.content or {}, child_ctx)

  if #content_lines == 0 then
    content_lines = {""}
  end

  local indent = string.rep("  ", depth - 1)
  local marker
  if list_kind == "ordered" then
    marker = string.format("%d. ", counter)
  else
    marker = "- "
  end

  content_lines[1] = indent .. marker .. content_lines[1]
  for i = 2, #content_lines do
    if content_lines[i] ~= "" then
      content_lines[i] = indent .. "  " .. content_lines[i]
    else
      content_lines[i] = indent .. "  "
    end
  end

  return content_lines
end

local function render_list(node, ctx, list_kind)
  local lines = {}
  local counter = 1

  if list_kind == "ordered" and node.attrs and node.attrs.order then
    local maybe_number = tonumber(node.attrs.order)
    if maybe_number and maybe_number >= 1 then
      counter = math.floor(maybe_number)
    end
  end

  for _, item in ipairs(node.content or {}) do
    local item_lines = render_list_item(item, ctx, list_kind, counter)
    vim.list_extend(lines, item_lines)
    if list_kind == "ordered" then
      counter = counter + 1
    end
  end

  return lines, { suppress_spacing = true }
end

local function render_panel(node, ctx)
  local attrs = node.attrs or {}
  local panel_type = attrs.panelType or "info"
  local inner_lines = render_nodes(node.content or {}, { list_depth = ctx and ctx.list_depth or 0, tight = false })

  if #inner_lines == 0 then
    return {}
  end

  table.insert(inner_lines, 1, string.format("> **%s**", panel_type:gsub("^%l", string.upper)))
  for i = 2, #inner_lines do
    if inner_lines[i] ~= "" then
      inner_lines[i] = "> " .. inner_lines[i]
    else
      inner_lines[i] = ">"
    end
  end

  return inner_lines
end

render_block_node = function(node, ctx)
  if type(node) ~= "table" then
    return {}, nil
  end

  local node_type = node.type

  if node_type == "doc" then
    local lines = render_nodes(node.content or {}, { list_depth = 0, tight = false })
    return lines, nil
  elseif node_type == "paragraph" then
    local text = render_inline_nodes(node.content or {})
    text = text:gsub("  \n", "\n")
    text = text:gsub("\n+$", "")
    text = vim.trim(text)
    if text == "" then
      return {}, nil
    end
    return { text }, nil
  elseif node_type == "heading" then
    local level = 1
    if node.attrs and node.attrs.level then
      local maybe_number = tonumber(node.attrs.level)
      if maybe_number then
        level = math.max(1, math.min(6, math.floor(maybe_number)))
      end
    end
    local text = vim.trim(render_inline_nodes(node.content or {}))
    return { string.rep("#", level) .. " " .. text }, nil
  elseif node_type == "bulletList" then
    return render_list(node, ctx or { list_depth = 0 }, "bullet")
  elseif node_type == "orderedList" then
    return render_list(node, ctx or { list_depth = 0 }, "ordered")
  elseif node_type == "blockquote" then
    return render_blockquote(node, ctx or { list_depth = 0 }), { suppress_spacing = true }
  elseif node_type == "codeBlock" then
    return render_code_block(node), nil
  elseif node_type == "rule" or node_type == "horizontalRule" then
    return { "---" }, nil
  elseif node_type == "panel" then
    return render_panel(node, ctx or { list_depth = 0 }), { suppress_spacing = true }
  elseif node_type == "table" then
    return render_table(node, ctx or { list_depth = 0 }), nil
  elseif node_type == "mediaSingle" or node_type == "media" then
    local attrs = node.attrs or {}
    local url = attrs.url or (attrs.fileName and (attrs.fileName .. (attrs.fileSize and string.format(" (%s)", attrs.fileSize) or "")))
    if not url or url == "" then
      url = attrs.id or ""
    end
    if url ~= "" then
      return { "![](" .. url .. ")" }, nil
    end
    return {}, nil
  elseif node_type == "taskList" then
    local lines = {}
    for _, item in ipairs(node.content or {}) do
      local attrs = item.attrs or {}
      local checked = attrs.state == "DONE" and "x" or " "
      local content = render_nodes(item.content or {}, { list_depth = 0, tight = true })
      local text = table.concat(content, " ")
      text = vim.trim(text)
      table.insert(lines, string.format("- [%s] %s", checked, text))
    end
    return lines, { suppress_spacing = true }
  end

  return {}, nil
end

local function adf_to_markdown(doc)
  if type(doc) ~= "table" then
    return nil
  end

  local lines = render_block_node(doc)
  if type(lines) == "table" then
    local markdown = table.concat(lines, "\n")
    markdown = markdown:gsub("%s+$", "")
    markdown = vim.trim(markdown)
    if markdown ~= "" then
      return markdown
    end
  end

  return nil
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

  if type(raw_description) == "table" then
    local markdown = adf_to_markdown(raw_description)
    if markdown and markdown ~= "" then
      return markdown
    end

    if adf_utils then
      if type(adf_utils.to_markdown) == "function" then
        local ok_md, parsed_markdown = pcall(adf_utils.to_markdown, raw_description)
        if ok_md then
          local trimmed_markdown = vim.trim(parsed_markdown or "")
          if trimmed_markdown ~= "" then
            return trimmed_markdown
          end
        end
      end

      if type(adf_utils.parse) == "function" then
        local ok_parse, parsed = pcall(adf_utils.parse, raw_description)
        if ok_parse then
          local trimmed = vim.trim(parsed or "")
          if trimmed ~= "" then
            return trimmed
          end
        end
      end
    end

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
