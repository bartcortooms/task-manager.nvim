# Task Manager – Jira Issue Selection & Branch Naming

This document describes the changes required to integrate Jira issue selection into the task creation workflow. It assumes no prior knowledge of the existing codebase beyond what is outlined here.

---

## 1. Objectives

1. Allow the user to pick from a list of Jira issues assigned to them, filtered to “not done” statuses.
2. Populate the task directory/branch name automatically using the selected issue key plus a slugified summary.
3. Keep manual entry as a fallback within the same flow.
4. Standardise prompts on `snacks.nvim`.
5. Treat `jirac.nvim` and `snacks.nvim` as hard dependencies (no custom fallback logic).

---

## 2. Dependencies

Add these plugins to `nvim/.config/nvim/lua/plugins/init.lua` (remove any earlier optional snippets so they load unconditionally):

```lua
{
  "folke/snacks.nvim",
  priority = 1000,
  opts = {
    input = {},
    picker = {},
  },
},
{
  "janBorowy/jirac.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  config = function()
    -- empty setup; we call jirac.setup ourselves with task-manager config
  end,
},
```

Remove any existing optional/snacks stubs or manual lazy-load hacks; the plugin should always be available.

---

## 3. Configuration Schema

Inside `task-manager` (default table in `init.lua`) add a `jira` section:

```lua
jira = {
  url = "",          -- https://company.atlassian.net
  email = "",
  api_token = function()
    return vim.fn.system("security find-generic-password -s 'Jira API Token' -w")
  end,
  jql = "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC",
  max_results = 50,
},
```

Validate these fields in `M.setup(opts)`, failing fast with a descriptive error. When a field is supplied as a function, call it and treat the return value as the credential (allowing keychain/CLI retrieval).

---

## 4. Jira Adapter Module

Create `lua/task-manager/jira.lua` alongside `init.lua`. Responsibilities:

### 4.1. `setup(config)`
* Accept the `jira` table from task-manager.
* Call `require("jirac").setup` with URL, email, token.

### 4.2. `fetch_assigned_issues()`
* Use `require("jirac.issues").search({ jql = ..., max_results = ... })`.
* Normalise each entry to `{ key = "DEP-123", summary = "...", raw = full_issue }`.
* Propagate errors with user-friendly messages (`vim.notify` from the caller).

Export both functions from the module. Add a small `resolve_value(value)` helper that calls `value()` when it is a function; normalise URL/email/token with it before passing into `jirac.setup` or the search call.

---

## 5. UI: Issue Picker

Implement `pick_issue()` in `init.lua` (or new `ui.lua` helper) with this flow:

1. Load issues via `jira.fetch_assigned_issues()`.
2. Convert to picker items: label `"DEP-123  |  Summary goes here"`, store `{ issue = item }`.
3. Prepend a manual option `{ label = "➕ Manual entry", issue = nil }`.
4. Invoke `require("snacks.picker").select` with:
   ```lua
   Snacks.picker.select({
     prompt = "Select Jira issue",
     items = vim.tbl_map(function(entry)
       return { text = entry.label, value = entry.issue }
     end, items),
     filter = "fuzzy",
   }, function(choice)
     -- choice.value is nil for manual entry
   end)
   ```
5. When the user picks:
   * `nil` → manual entry, return `{ manual = true }`.
   * otherwise return `{ manual = false, key = key, summary = summary }`.

Abort gracefully if the picker is cancelled (`return nil` up the stack so the task creation aborts).

---

## 6. Slug Helpers

Add utility functions (if not already present) to `init.lua` or a new `utils.lua`:

```lua
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
```

---

## 7. Task Creation Flow Rework

Replace the current issue/suffix prompts with this sequence:

1. Call `pick_issue()`.
2. **If manual:**
   * Prompt for issue key via `Snacks.input`.
   * Prompt for optional suffix via `Snacks.input`.
3. **If Jira issue selected:**
   * Use issue key directly.
   * Pre-populate suffix prompt with `slugify(summary)`, allow edits.
4. Compute `task_dir_name = build_task_name(issue_key, suffix)`.
5. Create/rename task directory as before.
6. Continue into repository picker and branch creation exactly as today (branch name = `task_dir_name`).

Ensure the manual path still validates the key (auto-prefix with `jira_prefix` when missing).

---

## 8. Cleanup

* Remove the old two-field Nui popup and any manual CLI inputs.
* Delete `derive_issue_slug` / `derive_task_suffix` helpers if unused.
* Remove any Snacks lazy-load hacks (plugin now loads eagerly).
* Update README (requirements + instructions).
* Document new config options in README (sample snippet).

---

## 9. Testing Checklist

1. **Config errors:** start Neovim without Jira credentials – verify descriptive error.
2. **Picker path:** select an issue, confirm:
   * suffix prompt pre-filled with slugged summary,
   * task directory + Git branch = `issue-suffix`,
   * repo picker still works.
3. **Manual path:** choose manual entry, supply key + suffix, confirm identical behaviour.
4. **Cancellation:** escape out of picker or inputs – task creation should abort without side effects.
5. **Multiple repos:** add second repo; branch name matches existing task directory.
7. **Manual cancellation:** cancel at any stage and confirm no directories/branches are created.
8. **Missing Jira credentials:** ensure `M.setup` raises a clear error.

---

## 10. Stretch Goals (Future)

* Display additional Jira metadata in the picker (status, updated date).
* Offer “open issue in browser” action as an extra key binding within the picker.

---

With this plan, a developer can drop the new Jira adapter module, wire snacks/jirac dependencies, and update the task creation flow without needing prior context. ***
