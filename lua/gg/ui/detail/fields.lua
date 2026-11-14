--- The field editors the issue, merge request and milestone views share:
--- title, people (assignees, reviewers), labels, milestone, dates and the
--- target branch. What is typed (a title, a date) is edited in an overlay
--- over its field (`gg.ui.detail.editing.field`); what is chosen (people,
--- labels, a milestone, a branch) in a filtered list over it
--- (`gg.ui.detail.editing.choice`). Either way the result is a payload.
local chooser = require("gg.ui.components.select")
local edit = require("gg.ui.detail.edit")
local editing = require("gg.ui.detail.editing")
local edits = require("gg.ui.detail.edits")
local gg = require("gg")
local ref_picker = require("gg.ui.create.ref_picker")
local refs = require("gg.ui.create.refs")

local M = {}

M.LIMIT = 500 -- members, labels, milestones loaded to choose from

--- What a project offers to choose from, loaded on first use.
---@param host string
---@param project string
---@return { members: gg.ui.Source, labels: gg.ui.Source, milestones: gg.ui.Source }
function M.sources(host, project)
  local args = { host = host, project = project }
  return {
    members = editing.source(function()
      return gg.users.project_members_all(args, { limit = M.LIMIT })
    end),
    labels = editing.source(function()
      return gg.labels.list_all(args, { limit = M.LIMIT })
    end),
    milestones = editing.source(function()
      return gg.milestones.list_all({ host = host, project = project, state = "active" }, { limit = M.LIMIT })
    end),
  }
end

---@class gg.ui.FieldCommon
---@field h gg.ui.DetailHost
---@field save fun(payload: any): gg.Task
---@field apply fun(result: any)
---@field changed? fun()
---@field render fun()

local function common(o, extra)
  return vim.tbl_extend("force", {
    save = o.save,
    apply = o.apply,
    changed = o.changed,
    render = o.render,
  }, extra)
end

-- `first` and then `rest`, each item once by `key` (case-insensitive)
local function merged(first, rest, key)
  local out, seen = {}, {}
  for _, list in ipairs({ first or {}, rest or {} }) do
    for _, item in ipairs(list) do
      local k = key(item):lower()
      if not seen[k] then
        seen[k] = true
        table.insert(out, item)
      end
    end
  end
  return out
end

local function names(items, key)
  return vim.tbl_map(key, items or {})
end

-- one line of a list: the value alone (no description, name or date), so
-- the list stays as narrow as the field
local function line_of(value, hl)
  local line = " " .. value
  return line, { { 0, #line, hl or "GitlabDetailValue" } }
end

local function username(u)
  return u.username
end

local function label_name(l)
  return l.name
end

--- The title, over the header's title. `required`: an empty title is
--- refused; otherwise it is no change.
---@param o gg.ui.FieldCommon|{ text: string, required?: boolean }
function M.title(o)
  return editing.field(o.h, common(o, {
    what = "title",
    pane = "header",
    region = "title",
    text = o.text,
    unchanged = function(t)
      return t == o.text or (t == "" and not o.required)
    end,
    parse = function(t)
      if t == "" then
        return nil, "Title cannot be empty"
      end
      return t
    end,
  }))
end

--- People (assignees or reviewers): ticked in a list of the project's
--- members (the current ones first); the payload is their ids.
---@param o gg.ui.FieldCommon|{ what: string, id: string, users: gg.User[], source: gg.ui.Source }
function M.people(o)
  o.source:get(function(members, err)
    if err then
      return edit.refuse(("Cannot load the project members: %s"):format(err.message or tostring(err)))
    end
    local current = names(o.users, username)
    -- the member's entry for who is set already; someone who is no member
    -- (any more) stays in the list as they are
    local by = {}
    for _, m in ipairs(members or {}) do
      by[m.username:lower()] = m
    end
    local set = vim.tbl_map(function(u)
      return by[u.username:lower()] or u
    end, o.users or {})
    local all = merged(set, members, username)
    editing.choice(o.h, common(o, {
      what = o.what,
      title = (o.what:gsub("^%l", string.upper)),
      id = o.id,
      pane = "sidebar",
      region = o.id,
      multi = true,
      fit = true,
      selected = set,
      key = username,
      -- the name is not shown, but typing it finds its user all the same
      load = chooser.static(all, function(u)
        return u.username .. " " .. (u.name or "")
      end),
      line = function(u)
        return line_of(u.username)
      end,
      unchanged = function(picked)
        local a, r = edits.diff(current, names(picked, username))
        return #a == 0 and #r == 0
      end,
      payload = function(picked)
        return vim.tbl_map(function(u)
          return u.id
        end, picked)
      end,
    }))
  end)
end

--- Labels: ticked in a list of the project's labels (the current ones
--- first); the payload is `{ add, remove }` (names).
---@param o gg.ui.FieldCommon|{ labels: gg.Label[], source: gg.ui.Source }
function M.labels(o)
  o.source:get(function(labels, err)
    if err then
      return edit.refuse(("Cannot load the labels: %s"):format(err.message or tostring(err)))
    end
    local current = names(o.labels, label_name)
    local all = merged(o.labels, labels, label_name)
    editing.choice(o.h, common(o, {
      what = "labels",
      title = "Labels",
      id = "labels",
      pane = "sidebar",
      region = "labels",
      multi = true,
      fit = true,
      selected = o.labels,
      key = label_name,
      load = chooser.static(all, label_name),
      line = function(l)
        return line_of(l.name)
      end,
      unchanged = function(picked)
        local a, r = edits.diff(current, names(picked, label_name))
        return #a == 0 and #r == 0
      end,
      payload = function(picked)
        local add, remove = edits.diff(current, names(picked, label_name))
        return { add = add, remove = remove }
      end,
    }))
  end)
end

local NO_MILESTONE = { none = true, title = "No milestone" }

local function milestone_key(m)
  return m.none and "none" or tostring(m.id)
end

--- The milestone: one of the active milestones, or none; the payload is
--- its id or false.
---@param o gg.ui.FieldCommon|{ milestone: gg.MilestoneRef|nil, source: gg.ui.Source }
function M.milestone(o)
  o.source:get(function(milestones, err)
    if err then
      return edit.refuse(("Cannot load the milestones: %s"):format(err.message or tostring(err)))
    end
    local current = o.milestone and milestone_key(o.milestone) or "none"
    -- the current one stays in the list when it is no longer active
    local all = merged({ NO_MILESTONE }, merged(milestones, { o.milestone }, milestone_key), milestone_key)
    editing.choice(o.h, common(o, {
      what = "milestone",
      title = "Milestone",
      id = "milestone",
      pane = "sidebar",
      region = "milestone",
      fit = true,
      current = current,
      key = milestone_key,
      load = chooser.static(all, function(m)
        return m.title
      end),
      line = function(m)
        return line_of(m.title, m.none and "GitlabDetailDim" or nil)
      end,
      unchanged = function(m)
        return milestone_key(m) == current
      end,
      payload = function(m)
        if m.none then
          return false
        end
        return m.id
      end,
    }))
  end)
end

--- A date over region `id` ("start_date" / "due_date") of `pane`; empty
--- clears it (payload false).
---@param o gg.ui.FieldCommon|{ id: string, label: string, pane: "header"|"sidebar", date: string|nil }
function M.date(o)
  local current = o.date or ""
  return editing.field(o.h, common(o, {
    what = o.label,
    id = o.id,
    pane = o.pane,
    region = o.id,
    text = current,
    unchanged = function(t)
      return t == current
    end,
    parse = function(t)
      local d = edits.date(t)
      if d == nil then
        return nil, ("Not a date (YYYY-MM-DD): %s"):format(t)
      end
      return d
    end,
  }))
end

--- The target branch of a merge request, chosen among the project's
--- branches (searched as you type).
---@param o gg.ui.FieldCommon|{ branch: string, host: string, project: string }
function M.target_branch(o)
  return editing.choice(o.h, common(o, {
    what = "target branch",
    title = "Target branch",
    id = "target_branch",
    pane = "sidebar",
    region = "target_branch",
    current = o.branch,
    key = function(b)
      return b.name
    end,
    load = refs.loader({ host = o.host, project = o.project }),
    line = ref_picker.line,
    unchanged = function(b)
      return b.name == (o.branch or "")
    end,
    payload = function(b)
      return b.name
    end,
  }))
end

return M
