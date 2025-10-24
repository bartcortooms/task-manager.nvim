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

return M
