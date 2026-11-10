--- The form for a new merge request: source and target branch, title,
--- assignees, draft and the description, prefilled by the caller (e.g. an
--- issue: its branch, `Draft: Resolve "<title>"`, `Closes #<iid>`, you).
---
--- `i` / `<CR>` on a field edits it (an overlay; the description in
--- place), `<C-s>` creates the merge request and the form gives way to its
--- detail view, `q` drops the form.
local doc = require("gg.ui.lib.doc")
local edit = require("gg.ui.detail.edit")
local editing = require("gg.ui.detail.editing")
local edits = require("gg.ui.detail.edits")
local field_edit = require("gg.ui.components.field_edit")
local gg = require("gg")
local header = require("gg.ui.detail.header")
local highlights = require("gg.ui.highlights")
local host = require("gg.ui.detail.host")
local line = require("gg.ui.lib.line")
local markdown = require("gg.ui.lib.markdown")
local chip = require("gg.ui.lib.chip")
local picker = require("gg.ui.components.picker")
local text_edit = require("gg.ui.components.text_edit")

local M = {}

M.LABEL_W = 12

---@class gg.ui.NewMergeRequest
---@field ctx gg.ui.DetailCtx
---@field h gg.ui.DetailHost
---@field screen gg.ui.Screen
---@field form { source_branch: string, target_branch: string, title: string, description: string, assignees: gg.User[], draft: boolean }
local View = {}
View.__index = View

--- Open the form (called through `gg.ui.detail.new_merge_request`).
---@param ctx gg.ui.DetailCtx
---@param draft table
---@return gg.ui.NewMergeRequest
function M.open(ctx, draft)
  highlights.setup()
  local self = setmetatable({
    ctx = ctx,
    project = ctx.project,
    form = {
      source_branch = draft.source_branch or "",
      target_branch = draft.target_branch or "",
      title = draft.title or "",
      description = draft.description or "",
      assignees = {},
      draft = (draft.title or ""):match("^Draft:") ~= nil,
    },
  }, View)
  self.h = host.new({
    stack = ctx.stack,
    cfg = ctx.cfg,
    name = "new_merge_request",
    on_render = function()
      self:render()
    end,
  })
  self.screen = self.h.screen
  self.members = editing.source(function()
    return gg.users.project_members_all({ host = ctx.host, project = self.project }, { limit = 500 })
  end, function(u)
    return { word = u.username, menu = u.name }
  end)
  local k = self.h.keys
  self.h:map("main", k.open_item, function()
    self:edit_current()
  end, "Edit the field")
  self.h:map("main", k.submit, function()
    self:create()
  end, "Create the merge request")
  -- the defaults that need GitLab: the target (default branch), you
  if self.form.target_branch == "" then
    gg.projects.get({ host = ctx.host, project = self.project }):on_done(function(p)
      if p and p.default_branch and self.form.target_branch == "" then
        self.form.target_branch = p.default_branch
        self:render()
      end
    end)
  end
  gg.users.current({ host = ctx.host }):on_done(function(u)
    if u and #self.form.assignees == 0 then
      self.form.assignees = { u }
      self:render()
    end
  end)
  self:render()
  self.h:set_cursor(2)
  return self
end

M.FIELDS = {
  { id = "source_branch", label = "Source" },
  { id = "target_branch", label = "Target" },
  { id = "title", label = "Title" },
  { id = "assignees", label = "Assignees" },
  { id = "draft", label = "Draft" },
}

--- The form as a document: one line per field (each a region for its
--- overlay), then the description.
---@param form table
---@param width integer
---@return gg.ui.Doc
function M.document(form, width)
  local d = doc.new()
  for _, f in ipairs(M.FIELDS) do
    local l = line.new():add(" "):add(f.label, "GitlabDetailLabel"):pad_to(M.LABEL_W)
    local col = l.bytes
    local value, hl
    if f.id == "assignees" then
      value = #form.assignees > 0 and table.concat(vim.tbl_map(function(u)
        return "@" .. u.username
      end, form.assignees), " ") or "unassigned"
      hl = #form.assignees > 0 and "GitlabDetailValue" or "GitlabDetailMuted"
    elseif f.id == "draft" then
      value, hl = form.draft and "yes" or "no", "GitlabDetailValue"
    else
      value = form[f.id] ~= "" and form[f.id] or "—"
      hl = (f.id:match("branch") and "GitlabBranchSource") or "GitlabDetailTitle"
      if f.id:match("branch") and form[f.id] ~= "" then
        value = "⎇ " .. value
      end
    end
    l:add(value, hl)
    local lnum = d:line(l, { kind = "field", id = f.id })
    d:region(f.id, lnum, col, math.max(20, width - M.LABEL_W - 2))
  end
  d:blank()
  d:line(line.new():add(" "):add("Description", "GitlabDetailLabel"), { kind = "field", id = "description" })
  local body = markdown.render(form.description, { width = width - 1, empty = "No description." })
  for i = 1, #body.lines do
    body.rows[i] = { kind = "field", id = "description" }
  end
  d:append(body)
  return d
end

--- Redraw the form.
function View:render()
  local h = self.h
  if h.closed then
    return
  end
  local pill = chip.pill("●", "New", "GitlabPillDraft")
  local body = header.build({ width = h:header_width(), pill = pill, title = self.form.title ~= "" and self.form.title or "New merge request", ref = "" })
  h:set_header(body, header.border_title(h:header_width(), header.crumb("merge requests"), "new", {}))
  h:set_content("main", M.document(self.form, h:content_width()))
  local k = h.keys
  h:set_title({ { " New merge request ", "GitlabDetailTabActive" } })
  h:set_hints("main", vim.tbl_filter(function(x)
    return x.key ~= nil
  end, {
    { key = picker.first_key(k.open_item), desc = "Edit" },
    { key = picker.first_key(k.submit), desc = "Create" },
    { key = picker.first_key(k.close), desc = "Discard" },
  }))
end

-- an overlay over a form field; `apply(text)` takes the value (false: keep editing)
---@private
function View:_field(id, text, opts, apply)
  local h = self.h
  local pos = h:region_pos("content", id)
  if not pos or h.editing then
    return
  end
  h:begin_edit({ kind = "field", id = id })
  field_edit.open(vim.tbl_extend("force", {
    row = pos.row,
    col = pos.col,
    width = pos.width,
    text = text,
    keys = h.keys,
    group = h.group,
    on_save = function(t, done)
      done(apply(t) ~= false)
    end,
    on_close = function()
      h:end_edit()
      self:render()
    end,
  }, opts or {}))
end

---@private
function View:_branch_complete(query, cb)
  gg.branches.list({ host = self.ctx.host, project = self.project, search = query ~= "" and query or nil }, { per_page = 50 }):on_done(function(page)
    cb(vim.tbl_map(function(b)
      return { word = b.name, menu = b.default and "default" or nil }
    end, page and page.items or {}))
  end)
end

--- `i` / `<CR>`: edit the field under the cursor.
function View:edit_current()
  local info = self.h:current()
  if not (info and info.id) then
    return
  end
  local id, form = info.id, self.form
  if id == "description" then
    if self.h.editing then
      return
    end
    self.h:begin_edit({ kind = "text" })
    text_edit.open({
      win = self.h.content_float.win,
      text = form.description,
      keys = self.h.keys,
      on_save = function(t, done)
        form.description = t
        done(true)
      end,
      on_close = function()
        self.h:end_edit()
        self:render()
      end,
    })
  elseif id == "draft" then
    form.draft = not form.draft
    if form.draft and not form.title:match("^Draft:") then
      form.title = "Draft: " .. form.title
    elseif not form.draft then
      form.title = form.title:gsub("^Draft:%s*", "")
    end
    self:render()
  elseif id == "assignees" then
    self.members:get(function(members)
      local current = vim.tbl_map(function(u)
        return u.username
      end, form.assignees)
      self:_field(id, table.concat(current, ", "), { multi = true, complete = self.members.complete }, function(t)
        local found, unknown = edits.resolve(edits.split(t), members or {}, function(u)
          return u.username
        end)
        if #unknown > 0 then
          edit.refuse("Skipping unrecognized: " .. table.concat(unknown, ", "))
        end
        form.assignees = found
      end)
    end)
  elseif id == "source_branch" or id == "target_branch" then
    self:_field(id, form[id], {
      complete = function(q, cb)
        self:_branch_complete(q, cb)
      end,
    }, function(t)
      form[id] = t
    end)
  elseif id == "title" then
    self:_field(id, form.title, {}, function(t)
      if t == "" then
        edit.refuse("Title cannot be empty")
        return false
      end
      form.title = t
      form.draft = t:match("^Draft:") ~= nil
    end)
  end
end

--- `<C-s>`: create the merge request; its detail view takes the form's place.
function View:create()
  local form = self.form
  if form.source_branch == "" or form.target_branch == "" then
    return edit.refuse("Source and target branch are required")
  end
  if form.title == "" then
    return edit.refuse("Title cannot be empty")
  end
  edit.run({
    what = "merge request",
    busy = "Creating the merge request…",
    success = "Merge request created",
    task = function()
      return gg.merge_requests.create({
        host = self.ctx.host,
        project = self.project,
        source_branch = form.source_branch,
        target_branch = form.target_branch,
        title = form.title,
        description = form.description,
        assignee_ids = vim.tbl_map(function(u)
          return u.id
        end, form.assignees),
      })
    end,
    alive = function()
      return not self.h.closed
    end,
    changed = function()
      self.ctx.stack:changed("merge_request")
      self.ctx.stack:changed("issue")
    end,
    apply = function(mr)
      local ctx = self.ctx
      ctx.stack:pop()
      require("gg.ui.detail").merge_request(vim.tbl_extend("force", {}, ctx, { stack = ctx.stack }), mr)
    end,
  })
end

return M
