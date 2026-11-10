--- The field editors the issue, merge request and milestone views share:
--- title, people (assignees, reviewers), labels, milestone, dates and the
--- target branch. Each opens an overlay over its field (see
--- `gg.ui.detail.editing.field`) and turns what was typed into a payload.
local edit = require("gg.ui.detail.edit")
local editing = require("gg.ui.detail.editing")
local edits = require("gg.ui.detail.edits")
local gg = require("gg")

local M = {}

M.LIMIT = 500 -- members, labels, milestones loaded for completion

--- Completion sources of a project, loaded on first use.
---@param host string
---@param project string
---@return { members: gg.ui.Source, labels: gg.ui.Source, milestones: gg.ui.Source }
function M.sources(host, project)
  local args = { host = host, project = project }
  return {
    members = editing.source(function()
      return gg.users.project_members_all(args, { limit = M.LIMIT })
    end, function(u)
      return { word = u.username, menu = u.name }
    end),
    labels = editing.source(function()
      return gg.labels.list_all(args, { limit = M.LIMIT })
    end, function(l)
      return { word = l.name }
    end),
    milestones = editing.source(function()
      return gg.milestones.list_all({ host = host, project = project, state = "active" }, { limit = M.LIMIT })
    end, function(m)
      return { word = m.title }
    end),
  }
end

local function skipped(unknown)
  if #unknown > 0 then
    edit.refuse("Skipping unrecognized: " .. table.concat(unknown, ", "))
  end
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

--- People (assignees or reviewers): usernames, comma-separated, completed
--- from the project's members; the payload is their ids.
---@param o gg.ui.FieldCommon|{ what: string, id: string, users: gg.User[], source: gg.ui.Source }
function M.people(o)
  o.source:get(function(members, err)
    if err then
      return edit.refuse(("Cannot load the project members: %s"):format(err.message or tostring(err)))
    end
    local current = vim.tbl_map(function(u)
      return u.username
    end, o.users or {})
    editing.field(o.h, common(o, {
      what = o.what,
      id = o.id,
      pane = "sidebar",
      region = o.id,
      text = table.concat(current, ", "),
      multi = true,
      complete = o.source.complete,
      unchanged = function(t)
        local a, r = edits.diff(current, edits.split(t))
        return #a == 0 and #r == 0
      end,
      parse = function(t)
        local found, unknown = edits.resolve(edits.split(t), members, function(u)
          return u.username
        end)
        skipped(unknown)
        return vim.tbl_map(function(u)
          return u.id
        end, found)
      end,
    }))
  end)
end

--- Labels, comma-separated, completed from the project's labels; the
--- payload is `{ add, remove }` (names).
---@param o gg.ui.FieldCommon|{ labels: gg.Label[], source: gg.ui.Source }
function M.labels(o)
  o.source:get(function(all, err)
    if err then
      return edit.refuse(("Cannot load the labels: %s"):format(err.message or tostring(err)))
    end
    local current = vim.tbl_map(function(l)
      return l.name
    end, o.labels or {})
    editing.field(o.h, common(o, {
      what = "labels",
      id = "labels",
      pane = "sidebar",
      region = "labels",
      text = table.concat(current, ", "),
      multi = true,
      complete = o.source.complete,
      unchanged = function(t)
        local a, r = edits.diff(current, edits.split(t))
        return #a == 0 and #r == 0
      end,
      parse = function(t)
        local found, unknown = edits.resolve(edits.split(t), all, function(l)
          return l.name
        end)
        skipped(unknown)
        local add, remove = edits.diff(current, vim.tbl_map(function(l)
          return l.name
        end, found))
        return { add = add, remove = remove }
      end,
    }))
  end)
end

--- The milestone: a title of an active milestone, or empty to remove it;
--- the payload is its id or false.
---@param o gg.ui.FieldCommon|{ milestone: gg.MilestoneRef|nil, source: gg.ui.Source }
function M.milestone(o)
  o.source:get(function(all, err)
    if err then
      return edit.refuse(("Cannot load the milestones: %s"):format(err.message or tostring(err)))
    end
    local current = o.milestone and o.milestone.title or ""
    editing.field(o.h, common(o, {
      what = "milestone",
      id = "milestone",
      pane = "sidebar",
      region = "milestone",
      text = current,
      complete = o.source.complete,
      unchanged = function(t)
        return t:lower() == current:lower()
      end,
      parse = function(t)
        if t == "" then
          return false
        end
        local found = edits.resolve({ t }, all, function(m)
          return m.title
        end)
        if not found[1] then
          return nil, "Unknown milestone: " .. t
        end
        return found[1].id
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

--- The target branch of a merge request, completed from the project's
--- branches (searched as you type).
---@param o gg.ui.FieldCommon|{ branch: string, host: string, project: string }
function M.target_branch(o)
  return editing.field(o.h, common(o, {
    what = "target branch",
    id = "target_branch",
    pane = "sidebar",
    region = "target_branch",
    text = o.branch or "",
    complete = function(query, cb)
      gg.branches.list({ host = o.host, project = o.project, search = query ~= "" and query or nil }, { per_page = 50 }):on_done(function(page)
        cb(vim.tbl_map(function(b)
          return { word = b.name, menu = b.default and "default" or nil }
        end, page and page.items or {}))
      end)
    end,
    unchanged = function(t)
      return t == (o.branch or "")
    end,
    parse = function(t)
      if t == "" then
        return nil, "The target branch cannot be empty"
      end
      return t
    end,
  }))
end

return M
