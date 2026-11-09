--- UI configuration: defaults, validation and the effective options.
---
--- Separate from `gg.setup()` (the API configuration). Like the API config,
--- this is the only module-level state of the UI ("configured defaults").
local gg = require("gg")

local M = {}

---@alias gg.ui.Keymap string|string[]|false a key (lhs), several keys, or false to disable the mapping

---@class gg.ui.Keymaps
---@field focus_filter gg.ui.Keymap Table: focus the filter (default "/")
---@field filter_submit gg.ui.Keymap Filter: back to the table, keep the filter (default "<CR>")
---@field filter_clear gg.ui.Keymap Filter: clear the filter, back to the table (default "<Esc><Esc>")
---@field inspect_issue gg.ui.Keymap Table: inspect the issue under the cursor (default "i")
---@field inspect_milestone gg.ui.Keymap Table: inspect its milestone (default "I")
---@field next_tab gg.ui.Keymap Table: Open -> Closed -> All (default "L")
---@field prev_tab gg.ui.Keymap Table: All -> Closed -> Open (default "H")
---@field next_page gg.ui.Keymap Table: next page, wraps to the first (default "P")
---@field next_milestone gg.ui.Keymap Table: next milestone block (default "]m")
---@field prev_milestone gg.ui.Keymap Table: previous milestone block (default "[m")
---@field refresh gg.ui.Keymap Table: reload from the API (default "R")
---@field close gg.ui.Keymap Table: close the picker (default "q")
---@field next_view gg.ui.Keymap Table: next view, issues -> merge requests (default "<Tab>")
---@field prev_view gg.ui.Keymap Table: previous view (default "<S-Tab>")
---@field inspect_mr gg.ui.Keymap Table: inspect the merge request under the cursor (default { "i", "<CR>" })

---@class gg.ui.InspectContext
---@field host string
---@field project string
---@field close fun() closes the picker

---@class gg.ui.Order
---@field top? fun(a: gg.Issue, b: gg.Issue): boolean issues without a milestone
---@field milestones? fun(a: gg.MilestoneRef, b: gg.MilestoneRef): boolean
---@field issues? fun(a: gg.Issue, b: gg.Issue): boolean issues inside a milestone

---@class gg.ui.Config
---@field limit integer upper bound on the items fetched per state, per view
---@field page_size integer rows per page
---@field filter_debounce_ms integer
---@field keymaps gg.ui.Keymaps
---@field order gg.ui.Order comparators; nil entries use the defaults
---@field on_inspect_issue fun(issue: gg.Issue, ctx: gg.ui.InspectContext)
---@field on_inspect_milestone fun(milestone: gg.MilestoneRef, ctx: gg.ui.InspectContext)
---@field on_inspect_mr fun(mr: gg.MergeRequest, ctx: gg.ui.InspectContext)
---@field user_colors table<string, string> username -> highlight group (e.g. "GitlabUser1")

local function default_inspect_issue(issue)
  vim.notify(("#%d %s\n%s"):format(issue.iid, issue.title or "", issue.web_url or ""), vim.log.levels.INFO)
end

local function default_inspect_milestone(milestone)
  vim.notify(("%%%s\n%s"):format(milestone.title or "", milestone.web_url or ""), vim.log.levels.INFO)
end

local function default_inspect_mr(mr)
  vim.notify(("!%d %s\n%s"):format(mr.iid, mr.title or "", mr.web_url or ""), vim.log.levels.INFO)
end

local function defaults()
  return {
    limit = 2000,
    page_size = 50,
    filter_debounce_ms = 50,
    keymaps = {
      focus_filter = "/",
      filter_submit = "<CR>",
      filter_clear = "<Esc><Esc>",
      inspect_issue = "i",
      inspect_milestone = "I",
      next_tab = "L",
      prev_tab = "H",
      next_page = "P",
      next_milestone = "]m",
      prev_milestone = "[m",
      refresh = "R",
      close = "q",
      next_view = "<Tab>",
      prev_view = "<S-Tab>",
      inspect_mr = { "i", "<CR>" },
    },
    order = {},
    on_inspect_issue = default_inspect_issue,
    on_inspect_milestone = default_inspect_milestone,
    on_inspect_mr = default_inspect_mr,
    user_colors = {},
  }
end

local current = defaults()

local function fail(key, msg)
  return gg.errors.new("validation", ("ui.%s: %s"):format(key, msg), { details = { key = key } })
end

local function check_int(v, key, min, max)
  if v ~= nil and (type(v) ~= "number" or math.floor(v) ~= v or v < min or (max and v > max)) then
    return fail(key, ("must be an integer from %d%s"):format(min, max and (" to " .. max) or " up"))
  end
end

local function check_fn(v, key)
  if v ~= nil and type(v) ~= "function" then
    return fail(key, "must be a function")
  end
end

local TOP = {
  limit = true,
  page_size = true,
  filter_debounce_ms = true,
  keymaps = true,
  order = true,
  on_inspect_issue = true,
  on_inspect_milestone = true,
  on_inspect_mr = true,
  user_colors = true,
}

local function is_key(v)
  return type(v) == "string" and v ~= ""
end

local function check_keymap(v, key)
  if v == false or is_key(v) then
    return nil
  end
  if type(v) == "table" and #v > 0 and vim.islist(v) then
    for _, lhs in ipairs(v) do
      if not is_key(lhs) then
        return fail(key, "must be a key string, a list of them, or false to disable it")
      end
    end
    return nil
  end
  return fail(key, "must be a key string, a list of them, or false to disable it")
end
local ORDER = { top = true, milestones = true, issues = true }

--- Validate UI options without applying them.
---@param opts any
---@return gg.Error|nil
function M.validate(opts)
  if opts == nil then
    return nil
  end
  if type(opts) ~= "table" then
    return fail("opts", "must be a table")
  end
  for k in pairs(opts) do
    if not TOP[k] then
      return fail(tostring(k), "unknown option")
    end
  end
  local err = check_int(opts.limit, "limit", 1)
    or check_int(opts.page_size, "page_size", 1)
    or check_int(opts.filter_debounce_ms, "filter_debounce_ms", 0, 10000)
    or check_fn(opts.on_inspect_issue, "on_inspect_issue")
    or check_fn(opts.on_inspect_milestone, "on_inspect_milestone")
    or check_fn(opts.on_inspect_mr, "on_inspect_mr")
  if err then
    return err
  end
  if opts.keymaps ~= nil then
    if type(opts.keymaps) ~= "table" then
      return fail("keymaps", "must be a table")
    end
    local known = defaults().keymaps
    for k, v in pairs(opts.keymaps) do
      if known[k] == nil then
        return fail("keymaps." .. tostring(k), "unknown keymap")
      end
      err = check_keymap(v, "keymaps." .. k)
      if err then
        return err
      end
    end
  end
  if opts.user_colors ~= nil then
    if type(opts.user_colors) ~= "table" then
      return fail("user_colors", "must be a table of username = highlight group")
    end
    for name, group in pairs(opts.user_colors) do
      if not is_key(name) or not is_key(group) then
        return fail("user_colors." .. tostring(name), "must map a username to a highlight group name")
      end
    end
  end
  if opts.order ~= nil then
    if type(opts.order) ~= "table" then
      return fail("order", "must be a table")
    end
    for k, v in pairs(opts.order) do
      if not ORDER[k] then
        return fail("order." .. tostring(k), "unknown option")
      end
      err = check_fn(v, "order." .. k)
      if err then
        return err
      end
    end
  end
  return nil
end

--- Apply UI options over the defaults. On failure the previous options stay.
---@param opts? table see gg.ui.Config
---@return boolean ok
---@return gg.Error|nil err
function M.setup(opts)
  local err = M.validate(opts)
  if err then
    return false, err
  end
  local merged = vim.tbl_deep_extend("force", defaults(), opts or {})
  -- a keymap given as a list replaces the default (no merge by index)
  for k, v in pairs(opts and opts.keymaps or {}) do
    merged.keymaps[k] = v
  end
  current = merged
  return true, nil
end

--- The effective UI options (a copy; callbacks are shared).
---@return gg.ui.Config
function M.get()
  return vim.deepcopy(current)
end

return M
