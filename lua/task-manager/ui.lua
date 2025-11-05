local task_utils = require("task-manager.task_utils")

local M = {}

function M.show_repo_menu(opts)
  opts = opts or {}
  local repos = opts.repos or {}
  if #repos == 0 then
    if opts.on_empty then
      opts.on_empty()
    end
    return
  end

  local task_label = opts.task_label or ""
  local task_dir = opts.task_dir or ""
  local Menu = require("nui.menu")

  local menu_items = {}
  for _, repo in ipairs(repos) do
    local repo_path = task_dir ~= "" and (task_dir .. "/" .. repo.name) or nil
    local exists = repo_path and vim.fn.isdirectory(repo_path) == 1
    local label
    if exists then
      label = "✓ " .. repo.name .. " (already added)"
    else
      label = "📦 " .. repo.name
    end
    menu_items[#menu_items + 1] = Menu.item(label, { repo = repo, exists = exists })
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
      if item.exists then
        if opts.on_exists then
          opts.on_exists(item.repo)
        else
          vim.notify("Repository already added to this task", vim.log.levels.WARN)
        end
        return
      end

      if opts.on_select then
        opts.on_select(item.repo)
      end
    end,
  })

  menu:mount()
end

function M.prompt_suffix(opts)
  opts = opts or {}
  local default_suffix = opts.default_suffix or ""
  local Snacks = require("snacks")

  Snacks.input({
    prompt = opts.prompt or "Branch suffix (optional)",
    default = default_suffix,
  }, function(value)
    if value == nil then
      if opts.on_cancel then
        opts.on_cancel()
      end
      return
    end

    local slugify = opts.slugify or task_utils.slugify
    local suffix = slugify(value)
    if opts.on_submit then
      opts.on_submit(suffix)
    end
  end)
end

function M.prompt_issue_key(opts)
  opts = opts or {}
  local Snacks = require("snacks")

  Snacks.input({
    prompt = opts.prompt or "Issue key (e.g. DEP-123)",
    default = opts.default_issue or "",
  }, function(value)
    if value == nil then
      if opts.on_cancel then
        opts.on_cancel()
      end
      return
    end

    local parse_issue_string = opts.parse_issue_string or task_utils.parse_issue_string
    local issue_key, inline_suffix = parse_issue_string(value, opts.jira_prefix)
    if not issue_key then
      if opts.on_invalid then
        opts.on_invalid()
      else
        vim.notify("Issue key is required", vim.log.levels.ERROR)
      end
      return
    end

    if opts.on_submit then
      opts.on_submit(issue_key, inline_suffix or "")
    end
  end)
end

function M.pick_issue(opts)
  opts = opts or {}
  local entries = opts.entries or {}

  local Snacks = require("snacks")

  local items = vim.tbl_map(function(entry)
    return { label = entry.label, issue = entry.issue }
  end, entries)

  Snacks.picker.select(items, {
    prompt = opts.prompt or "Select Jira issue",
    filter = "fuzzy",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      if opts.on_cancel then
        opts.on_cancel()
      end
      return
    end

    if not choice.issue then
      if opts.on_manual then
        opts.on_manual()
      end
      return
    end

    if opts.on_issue then
      opts.on_issue(choice.issue)
    end
  end)
end

function M.list_tasks_picker(opts)
  opts = opts or {}
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local entries = opts.entries or {}

  pickers.new({}, {
    prompt_title = opts.prompt_title or "Tasks",
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
      if opts.on_delete then
        local function delete_selected()
          local selection = action_state.get_selected_entry()
          if not selection or selection.value.kind ~= "task" then
            vim.notify("Select a task before deleting", vim.log.levels.WARN)
            return
          end
          actions.close(prompt_bufnr)
          opts.on_delete(selection.value.task)
        end
        map("i", "<C-d>", delete_selected)
        map("n", "d", delete_selected)
      end

      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if not selection then
          return
        end

        local entry = selection.value
        if opts.on_select then
          opts.on_select(entry)
        end
      end)
      return true
    end,
  }):find()
end

function M.list_repos_picker(opts)
  opts = opts or {}
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local repos = opts.repos or {}

  pickers.new({}, {
    prompt_title = opts.prompt_title or "Task Repositories",
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
        if selection and opts.on_select then
          opts.on_select(selection.value)
        end
      end)
      return true
    end,
  }):find()
end

function M.confirm_yes_no(opts)
  opts = opts or {}
  local Snacks = require("snacks")

  local choices = {
    { label = opts.yes_label or "Yes", value = true },
    { label = opts.no_label or "No", value = false },
  }

  Snacks.picker.select(choices, {
    prompt = opts.prompt or "Confirm selection",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      if opts.on_cancel then
        opts.on_cancel()
      end
      if opts.on_confirm then
        opts.on_confirm(false, nil)
      end
      return
    end

    if choice.value then
      if opts.on_yes then
        opts.on_yes(choice)
      end
      if opts.on_confirm then
        opts.on_confirm(true, choice)
      end
    else
      if opts.on_no then
        opts.on_no(choice)
      end
      if opts.on_confirm then
        opts.on_confirm(false, choice)
      end
    end
  end)
end

local function truncate_field(text, max_len)
  if not text then
    return ""
  end
  local str = tostring(text)
  if #str <= max_len then
    return str
  end
  if max_len <= 3 then
    return str:sub(1, max_len)
  end
  return str:sub(1, max_len - 3) .. "..."
end

local function format_pr_entry(item)
  local branch = truncate_field(item.branch or "-", 20)
  local status
  local summary

  if item.pr then
    status = item.pr.state or "open"
    if item.pr.isDraft then
      status = status .. " (draft)"
    end
    summary = item.pr.title or ""
  elseif item.error then
    status = "error"
    summary = item.error
  else
    status = item.status or "unknown"
    summary = ""
  end

  local repo = item.repo_slug or ""
  return string.format("%-18s %-20s %-12s %-16s %s", item.worktree_name or "", branch, status, repo, summary)
end

function M.show_pr_overview(items, opts)
  opts = opts or {}
  if not items or vim.tbl_isempty(items) then
    vim.notify("No pull requests found for current context.", vim.log.levels.INFO)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  pickers.new({}, {
    prompt_title = opts.prompt_title or "Task PR Overview",
    finder = finders.new_table({
      results = items,
      entry_maker = function(item)
        return {
          value = item,
          display = format_pr_entry(item),
          ordinal = table.concat({
            item.worktree_name or "",
            item.branch or "",
            item.status or "",
            item.repo_slug or "",
            item.pr and item.pr.title or "",
          }, " "),
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      define_preview = function(self, entry, _)
        local item = entry.value
        local buf = self.state.bufnr
        vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
        vim.api.nvim_buf_set_option(buf, "modifiable", true)

        local function extend_lines(target, text)
          if not text or text == "" then
            return
          end
          local normalized = text:gsub("\r\n", "\n"):gsub("\r", "\n")
          local chunks = vim.split(normalized, "\n", { plain = true, trimempty = false })
          vim.list_extend(target, chunks)
        end

        if not item then
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "No pull request details available." })
          return
        end

        if not item.pr then
          local lines = {
            "# Pull request not found",
            "",
            ("Repository: %s"):format(item.repo_slug or "-"),
            ("Branch: %s"):format(item.branch or "-"),
          }
          if item.error then
            table.insert(lines, "")
            table.insert(lines, "Error:")
            extend_lines(lines, item.error)
          elseif item.status then
            table.insert(lines, "")
            table.insert(lines, ("Status: %s"):format(item.status))
          end
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
          return
        end

        local pr = item.pr
        local lines = {}
        local title = pr.title or ""
        if title ~= "" then
          table.insert(lines, "# " .. title)
          table.insert(lines, "")
        end

        table.insert(lines, ("State: %s"):format(pr.state or "-"))
        if pr.mergeStateStatus then
          table.insert(lines, ("Merge State: %s"):format(pr.mergeStateStatus))
        end
        if pr.isDraft then
          table.insert(lines, "Draft: yes")
        end
        table.insert(lines, ("Branch: %s"):format(pr.headRefName or item.branch or "-"))
        table.insert(lines, ("Repository: %s"):format(item.repo_slug or "-"))

        local body = pr.bodyText or pr.body or ""
        if body ~= "" then
          table.insert(lines, "")
          extend_lines(lines, body)
        end

        if vim.tbl_isempty(lines) then
          lines = { "No pull request details available." }
        end

        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.api.nvim_buf_set_option(buf, "modifiable", false)
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      local function handle_open_pr()
        local selection = action_state.get_selected_entry()
        if not selection then
          return
        end
        actions.close(prompt_bufnr)
        if opts.on_open_pr then
          opts.on_open_pr(selection.value)
        end
      end

      local function handle_open_repo()
        local selection = action_state.get_selected_entry()
        if not selection then
          return
        end
        actions.close(prompt_bufnr)
        if opts.on_open_repo then
          opts.on_open_repo(selection.value)
        end
      end

      actions.select_default:replace(handle_open_pr)
      if opts.on_open_repo then
        map("i", "<C-r>", handle_open_repo)
        map("n", "r", handle_open_repo)
      end

      return true
    end,
  }):find()
end

return M
