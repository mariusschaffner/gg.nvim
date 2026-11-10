--- The creation popup: one design for every "new …" view.
---
--- A view is a definition (`gg.ui.CreateDef`, see `gg.ui.create.defs.*`):
--- what the floats are called, which fields the field row has, what the
--- body is, and the functions that prefill, check and send it. The popup
--- owns everything else: the windows (title, field row, body) over 70 % of
--- the editor, the focus cycle, placeholders, cancel with a discard
--- question, the submit state in the body's border and where errors show.
---
--- It is a screen of the picker's stack. After a successful submit it pops
--- itself, tells the screens below what changed and lets the definition
--- show the new item.
local confirm = require("gg.ui.components.confirm")
local float_group = require("gg.ui.components.float_group")
local highlights = require("gg.ui.highlights")
local layout = require("gg.ui.components.layout")
local create_layout = require("gg.ui.create.layout")
local model = require("gg.ui.create.model")
local picker = require("gg.ui.components.picker")
local placeholders = require("gg.ui.create.placeholders")

local M = {}

---@class gg.ui.CreateField
---@field id string
---@field keymap string the name of the keymap option that edits it ("create_source")
---@field label string
---@field icon? string drawn before the value ("⎇")
---@field hl? string highlight group of the value
---@field empty? string what an unset field shows
---@field pick fun(p: gg.ui.CreatePopup, field: gg.ui.CreateField) let the user choose a value (then `p:set_field`)

---@class gg.ui.CreateValues
---@field title string trimmed
---@field description string the body without trailing blank lines
---@field lines string[] the body's lines as they are
---@field fields table<string, string> field id -> value (unset fields are missing)

---@class gg.ui.CreateDef
---@field kind string "issue" | "merge_request" | "milestone" | "pipeline"
---@field accent string highlight group of the title float's border
---@field icon string
---@field label string "New issue"
---@field entity string the body's right border label ("Issue")
---@field title { readonly?: boolean, placeholder?: string }
---@field fields gg.ui.CreateField[] the field row, left to right (0 to 2)
---@field body { filetype?: string }
---@field hints fun(p: gg.ui.CreatePopup): gg.ui.Hint[] the body's bottom-left hints
---@field submit_label string "Create"
---@field busy_label string "creating…"
---@field api_fields table<string, string> API field name -> float ("title", "body", "field_<id>") for error messages
---@field changed string[] the kinds a submit changes (see `Stack:changed`)
---@field setup? fun(p: gg.ui.CreatePopup) the windows are open: prefill, extra keys
---@field validate? fun(p: gg.ui.CreatePopup, v: gg.ui.CreateValues): string|nil, string|nil a message and the float it belongs to
---@field precheck? fun(p: gg.ui.CreatePopup, v: gg.ui.CreateValues, go: fun(), stop: fun(message?: string, member?: string)) checks that need GitLab or the user; ends with `go()` (send) or `stop()` (do not; with a message: show it as an error)
---@field submit fun(p: gg.ui.CreatePopup, v: gg.ui.CreateValues): gg.Task
---@field show fun(ctx: gg.ui.DetailCtx, item: any) open what was created (the popup is gone)

---@class gg.ui.CreatePopup
---@field ctx gg.ui.DetailCtx
---@field def gg.ui.CreateDef
---@field preset table what the caller passed along (values sent but not shown, prefills)
---@field keys gg.ui.Keymaps
---@field group gg.ui.FloatGroup
---@field screen gg.ui.Screen
---@field title_float gg.ui.Float
---@field body_float gg.ui.Float
---@field state gg.ui.CreateState
---@field closed boolean
---@field data table free for the definition (requests, lookups)
local Popup = {}
Popup.__index = Popup

local BODY_WIN_OPTS = {
  number = true,
  relativenumber = false,
  cursorline = true,
  wrap = true,
  linebreak = true,
  signcolumn = "no",
  foldcolumn = "0",
  spell = false,
  list = false,
}

local LINE_WIN_OPTS = { wrap = false, number = false, signcolumn = "no", cursorline = false }

local function first_key(k)
  return picker.first_key(k)
end

--- The float name of field `id`.
---@param id string
---@return string
function M.field_member(id)
  return "field_" .. id
end

-- replace a buffer's lines without leaving an undo step (a prefill is not
-- something `u` should take away)
local function set_lines(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local modifiable, levels = vim.bo[buf].modifiable, vim.bo[buf].undolevels
  vim.bo[buf].modifiable = true
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = levels
  vim.bo[buf].modifiable = modifiable
end

--- Open the popup for `def` on `ctx.stack`'s top (call it inside
--- `stack:push`; `popup.screen` is the screen).
---@param ctx gg.ui.DetailCtx
---@param def gg.ui.CreateDef
---@param preset? table
---@return gg.ui.CreatePopup
function M.open(ctx, def, preset)
  highlights.setup()
  local self = setmetatable({
    ctx = ctx,
    def = def,
    preset = preset or {},
    keys = ctx.cfg.keymaps,
    state = "idle",
    closed = false,
    data = {},
    fields = {}, -- id -> { value, note }
    field_floats = {},
    _listeners = {},
    _entity = def.entity,
    ns = vim.api.nvim_create_namespace("gg.ui.create"),
    diag_ns = vim.api.nvim_create_namespace("gg.ui.create.diagnostics"),
  }, Popup)

  self.group = float_group.new({
    layout = function()
      return self:_rects()
    end,
  })
  self.title_float = self.group:add({
    name = "title",
    title = model.title_label(def),
    -- the accent colour, focused or not
    border_hl = def.accent,
    border_active_hl = def.accent,
    filetype = "gg_ui_create_title",
    win_opts = LINE_WIN_OPTS,
  })
  vim.fn.matchadd("GitlabCreateTitle", ".*", 10, -1, { window = self.title_float.win })
  vim.bo[self.title_float.buf].modifiable = not def.title.readonly
  for _, f in ipairs(def.fields) do
    local fl = self.group:add({
      name = M.field_member(f.id),
      title = model.key_label(first_key(self.keys[f.keymap]), f.label),
      filetype = "gg_ui_create_field",
      win_opts = LINE_WIN_OPTS,
    })
    vim.bo[fl.buf].modifiable = false
    self.field_floats[f.id] = fl
    self.fields[f.id] = {}
  end
  self.body_float = self.group:add({
    name = "body",
    title = model.key_label("i", "Edit"),
    title_right = self:_entity_label(),
    footer = model.hints(def.hints(self)),
    footer_right = self:_submit_label(),
    filetype = def.body.filetype or "markdown",
    win_opts = BODY_WIN_OPTS,
    winhighlight = "CursorLine:GitlabCursorLine",
  })
  for _, f in ipairs(def.fields) do
    self:_draw_field(f.id)
  end

  self:_keymaps()
  self:_watch()
  self.group:on_close(function()
    self:_teardown()
  end)
  ---@type gg.ui.Screen
  self.screen = { group = self.group }

  self:_decorate_title()
  self:mark_clean()
  self.group:focus("body")
  if def.setup then
    def.setup(self)
  end
  return self
end

---@private
function Popup:_rects()
  local r = create_layout.rects(#self.def.fields, layout.editor())
  local out = { title = r.title, body = r.body }
  for i, f in ipairs(self.def.fields) do
    out[M.field_member(f.id)] = r.fields[i]
  end
  return out
end

---@private
function Popup:_entity_label()
  return { { (" %s "):format(self._entity), "GitlabCreateHint" } }
end

---@private
function Popup:_submit_label()
  return model.submit_label(self.state, {
    key = first_key(self.keys.submit),
    submit = self.def.submit_label,
    busy = self._checking and "checking…" or self.def.busy_label,
    error = self._error,
  })
end

--- The key hints show for keymap option `name` (nil when it is disabled).
---@param name string
---@return string|nil
function Popup:key(name)
  return first_key(self.keys[name])
end

--- Change the body's right border label ("Variables · 3").
---@param text string
function Popup:set_entity(text)
  if self.closed or text == self._entity then
    return
  end
  self._entity = text
  self.group:set_labels("body", { title_right = self:_entity_label() })
end

---@private
function Popup:_set_state(state, message)
  if self.closed then
    return
  end
  self.state, self._error = state, message
  self.group:set_labels("body", { footer_right = self:_submit_label() })
end

-- every buffer of the popup: name -> buffer
---@private
function Popup:_bufs()
  local out = { title = self.title_float.buf, body = self.body_float.buf }
  for id, f in pairs(self.field_floats) do
    out[M.field_member(id)] = f.buf
  end
  return out
end

---@private
function Popup:_map(buf, modes, k, fn, desc)
  for _, lhs in ipairs(picker.lhs_list(k)) do
    vim.keymap.set(modes, lhs, fn, { buffer = buf, silent = true, desc = desc })
  end
end

--- Map keymap option `k` in the body (normal mode).
---@param k gg.ui.Keymap
---@param fn fun()
---@param desc string
function Popup:map_body(k, fn, desc)
  self:_map(self.body_float.buf, "n", k, fn, desc)
end

---@private
function Popup:_keymaps()
  local k = self.keys
  for name, buf in pairs(self:_bufs()) do
    self:_map(buf, "n", k.create_next_field, function()
      self:cycle(1)
    end, "Next field")
    self:_map(buf, "n", k.create_prev_field, function()
      self:cycle(-1)
    end, "Previous field")
    self:_map(buf, { "n", "i" }, k.submit, function()
      self:submit()
    end, self.def.submit_label)
    self:_map(buf, "n", k.create_cancel, function()
      self:cancel()
    end, "Cancel")
    self:_map(buf, { "n", "i" }, k.next_placeholder, function()
      self:jump_placeholder(1)
    end, "Next placeholder")
    self:_map(buf, { "n", "i" }, k.prev_placeholder, function()
      self:jump_placeholder(-1)
    end, "Previous placeholder")
    for _, f in ipairs(self.def.fields) do
      self:_map(buf, "n", k[f.keymap], function()
        self:pick(f.id)
      end, f.label)
      if name == M.field_member(f.id) then
        self:_map(buf, "n", { "<CR>", "i", "a" }, function()
          self:pick(f.id)
        end, f.label)
      end
    end
  end
  -- the title is one line: Tab and Enter leave it, also while typing
  local tb = self.title_float.buf
  self:_map(tb, "i", k.create_next_field, function()
    vim.cmd("stopinsert")
    self:cycle(1)
  end, "Next field")
  self:_map(tb, "i", k.create_prev_field, function()
    vim.cmd("stopinsert")
    self:cycle(-1)
  end, "Previous field")
  self:_map(tb, { "n", "i" }, "<CR>", function()
    vim.cmd("stopinsert")
    self:focus("body")
  end, "To the description")
end

---@private
function Popup:_watch()
  self.augroup = vim.api.nvim_create_augroup(("gg.ui.create.%d"):format(self.body_float.buf), { clear = true })
  for name, buf in pairs({ title = self.title_float.buf, body = self.body_float.buf }) do
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
      group = self.augroup,
      buffer = buf,
      callback = function()
        self:_changed(name)
      end,
    })
  end
end

---@private
function Popup:_changed(name)
  if self.closed then
    return
  end
  if name == "title" then
    -- one line (a paste may bring more)
    local buf = self.title_float.buf
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if #lines > 1 then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { table.concat(lines, " ") })
    end
    self:_decorate_title()
  end
  local buf = self:_bufs()[name]
  if not self._keep_diagnostics then
    vim.diagnostic.reset(self.diag_ns, buf)
  end
  if self.state == "error" then
    self:_set_state("idle")
  end
  for _, fn in ipairs(self._listeners) do
    fn(name)
  end
end

--- Run `fn(member)` after the title ("title") or the body ("body") changed.
---@param fn fun(member: string)
function Popup:on_change(fn)
  table.insert(self._listeners, fn)
end

---@private
function Popup:_decorate_title()
  local buf = self.title_float.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, self.ns, 0, -1)
  local ph = self.def.title.placeholder
  if ph and self:title() == "" then
    vim.api.nvim_buf_set_extmark(buf, self.ns, 0, 0, { virt_text = { { ph, "GitlabCreatePlaceholder" } }, virt_text_pos = "overlay" })
  end
end

--- The title, trimmed.
---@return string
function Popup:title()
  local buf = self.title_float.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return ""
  end
  return vim.trim(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
end

--- The body's lines.
---@return string[]
function Popup:body_lines()
  local buf = self.body_float.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return {}
  end
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

-- a change the popup makes itself (a prefill) is not a change of the user's
---@private
function Popup:_prefill(fn)
  local was_dirty = self:dirty()
  self._keep_diagnostics = true
  fn()
  self._keep_diagnostics = false
  if not was_dirty then
    self:mark_clean()
  end
end

--- Set the title (a prefill: it does not count as a change).
---@param text string
function Popup:set_title(text)
  if self.closed then
    return
  end
  self:_prefill(function()
    set_lines(self.title_float.buf, { (text:gsub("[\r\n]", " ")) })
    self:_decorate_title()
  end)
end

--- Set the body (a prefill: it does not count as a change).
---@param lines string[]
function Popup:set_body(lines)
  if self.closed then
    return
  end
  self:_prefill(function()
    set_lines(self.body_float.buf, #lines > 0 and lines or { "" })
  end)
  for _, fn in ipairs(self._listeners) do
    fn("body")
  end
end

--- The value of field `id` (nil while unset).
---@param id string
---@return string|nil
function Popup:field(id)
  local f = self.fields[id]
  return f and f.value or nil
end

--- Set field `id`; `note` is drawn dimmed after the value (a commit, a
--- hint). `opts.prefill` keeps it from counting as a change.
---@param id string
---@param value string|nil
---@param note? string
---@param opts? { prefill?: boolean }
function Popup:set_field(id, value, note, opts)
  if self.closed or not self.fields[id] then
    return
  end
  local function apply()
    self.fields[id] = { value = value ~= "" and value or nil, note = note }
    self:_draw_field(id)
  end
  if opts and opts.prefill then
    self:_prefill(apply)
  else
    apply()
    vim.diagnostic.reset(self.diag_ns, self.field_floats[id].buf)
    if self.state == "error" then
      self:_set_state("idle")
    end
  end
end

--- Change only the dimmed note of field `id`.
---@param id string
---@param note string|nil
function Popup:set_field_note(id, note)
  if self.closed or not self.fields[id] then
    return
  end
  self.fields[id].note = note
  self:_draw_field(id)
end

---@private
function Popup:_field_def(id)
  for _, f in ipairs(self.def.fields) do
    if f.id == id then
      return f
    end
  end
end

---@private
function Popup:_draw_field(id)
  local def, state, fl = self:_field_def(id), self.fields[id], self.field_floats[id]
  if not (def and fl and vim.api.nvim_buf_is_valid(fl.buf)) then
    return
  end
  local parts = {} -- { text, hl }
  if state.value then
    local value = (def.icon and (def.icon .. " ") or "") .. state.value
    table.insert(parts, { value, def.hl or "GitlabDetailValue" })
  else
    table.insert(parts, { def.empty or "—", "GitlabCreatePlaceholder" })
  end
  if state.note and state.note ~= "" then
    table.insert(parts, { "  " .. state.note:gsub("%c", " "), "GitlabCreateDim" })
  end
  local line, marks = "", {}
  for _, p in ipairs(parts) do
    table.insert(marks, { #line, #line + #p[1], p[2] })
    line = line .. p[1]
  end
  set_lines(fl.buf, { line })
  vim.api.nvim_buf_clear_namespace(fl.buf, self.ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(fl.buf, self.ns, 0, m[1], { end_col = m[2], hl_group = m[3] })
  end
end

--- Where field `id`'s text starts on the screen and how wide it is (for an
--- overlay or a list below it).
---@param id string
---@return gg.ui.Rect|nil
function Popup:field_rect(id)
  return self:_rects()[M.field_member(id)]
end

--- Edit field `id` as text, in an overlay laid over its float. `parse`
--- turns the text into the value ("" unsets the field); when it returns
--- nil and a message, the message is shown and the overlay stays.
---@param id string
---@param parse fun(text: string): string|nil, string|nil
function Popup:edit_field(id, parse)
  local rect = self:field_rect(id)
  if self.closed or not rect or self._overlay then
    return
  end
  self._overlay = require("gg.ui.components.field_edit").open({
    row = rect.row + 1,
    col = rect.col + 1,
    width = rect.width,
    limit = rect.col + 1 + rect.width,
    text = self:field(id) or "",
    keys = self.keys,
    group = self.group,
    on_save = function(text, done)
      local value, why = parse(text)
      if value == nil then
        vim.notify("gg.ui: " .. (why or "Invalid value"), vim.log.levels.WARN)
        return done(false)
      end
      self:set_field(id, value)
      done(true)
    end,
    on_close = function()
      self._overlay = nil
      if not self.closed then
        self:focus(M.field_member(id))
      end
    end,
  })
end

--- Let the user choose field `id`.
---@param id string
function Popup:pick(id)
  local def = self:_field_def(id)
  if def and self.state ~= "busy" and not self.closed then
    def.pick(self, def)
  end
end

--- What the popup holds now.
---@return gg.ui.CreateValues
function Popup:values()
  local lines = self:body_lines()
  local fields = {}
  for id, f in pairs(self.fields) do
    fields[id] = f.value
  end
  return { title = self:title(), description = model.body_text(lines), lines = lines, fields = fields }
end

---@private
function Popup:_snapshot()
  local v = self:values()
  return { title = v.title, body = v.lines, fields = v.fields }
end

--- Take the current content as the unchanged state.
function Popup:mark_clean()
  self._initial = self:_snapshot()
end

--- True when the user changed something since the popup opened.
---@return boolean
function Popup:dirty()
  return self._initial ~= nil and model.dirty(self._initial, self:_snapshot())
end

-- the floats in focus order: title, fields, body (a read-only title is skipped)
---@private
function Popup:_order()
  local order = {}
  if not self.def.title.readonly then
    table.insert(order, "title")
  end
  for _, f in ipairs(self.def.fields) do
    table.insert(order, M.field_member(f.id))
  end
  table.insert(order, "body")
  return order
end

--- Focus float `name` ("title", "body", or a field's member name).
---@param name string
function Popup:focus(name)
  if not self.closed then
    self.group:focus(name)
  end
end

--- Focus the next (1) or previous (-1) float.
---@param dir integer
function Popup:cycle(dir)
  if self.closed then
    return
  end
  local cur = self.group:name_of(vim.api.nvim_get_current_win())
  local name = model.cycle(self:_order(), cur, dir)
  if name then
    self:focus(name)
  end
end

--- Jump to the next (1) or previous (-1) `‹placeholder›` of the focused
--- float and select it, so typing replaces it. Returns false without one.
---@param dir integer
---@return boolean
function Popup:jump_placeholder(dir)
  local win = vim.api.nvim_get_current_win()
  local name = self.group:name_of(win)
  if self.closed or (name ~= "title" and name ~= "body") then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local pos = vim.api.nvim_win_get_cursor(win)
  local span = placeholders.step(placeholders.find(vim.api.nvim_buf_get_lines(buf, 0, -1, false)), pos[1], pos[2], dir)
  if not span then
    return false
  end
  self:select(win, span)
  return true
end

--- Select `span` in `win` (select mode: typing replaces it), once insert
--- mode has ended.
---@param win integer
---@param span gg.ui.Placeholder
function Popup:select(win, span)
  vim.cmd("stopinsert")
  vim.schedule(function()
    if self.closed or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_get_current_win() ~= win then
      return
    end
    if vim.api.nvim_get_mode().mode ~= "n" then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    end
    vim.api.nvim_win_set_cursor(win, { span.row, span.col })
    vim.cmd("normal! v")
    vim.api.nvim_win_set_cursor(win, { span.row, span.end_col - #placeholders.CLOSE })
    vim.cmd([[execute "normal! \<C-g>"]])
  end)
end

--- Put the cursor where writing starts: the title (in insert mode) while
--- it is empty and editable, else the body's first placeholder (selected),
--- else the body.
function Popup:start()
  if self.closed then
    return
  end
  if not self.def.title.readonly and self:title() == "" then
    self:focus("title")
    vim.cmd("startinsert!")
    return
  end
  self:focus("body")
  pcall(vim.api.nvim_win_set_cursor, self.body_float.win, { 1, 0 })
  local first = placeholders.find(self:body_lines())[1]
  if first then
    self:select(self.body_float.win, first)
  end
end

--- Show `message` as an error: in the body's border, as a diagnostic in
--- float `member` (when given) and as a notification.
---@param message string
---@param member? string "title", "body" or a field's member name
---@param level? integer vim.log.levels (default ERROR)
function Popup:fail(message, member, level)
  if self.closed then
    return
  end
  self:_set_state("error", message)
  local buf = member and self:_bufs()[member]
  if buf then
    self:_diagnose(buf, { { lnum = 0, col = 0, message = message } })
    self:focus(member)
  end
  vim.notify("gg.ui: " .. message, level or vim.log.levels.ERROR)
end

--- Diagnostics in the body (bad lines of the variables editor); `{}` clears.
---@param items { lnum: integer, col: integer, end_col?: integer, message: string }[] 0-based lines
function Popup:diagnose_body(items)
  if not self.closed then
    self:_diagnose(self.body_float.buf, items)
  end
end

---@private
function Popup:_diagnose(buf, items)
  local list = {}
  for _, d in ipairs(items) do
    table.insert(list, {
      lnum = d.lnum,
      col = d.col or 0,
      end_col = d.end_col,
      message = d.message,
      severity = vim.diagnostic.severity.ERROR,
      source = "gg",
    })
  end
  vim.diagnostic.set(self.diag_ns, buf, list)
end

---@private
function Popup:_lock(locked)
  if vim.api.nvim_buf_is_valid(self.body_float.buf) then
    vim.bo[self.body_float.buf].modifiable = not locked
  end
  if vim.api.nvim_buf_is_valid(self.title_float.buf) then
    vim.bo[self.title_float.buf].modifiable = not locked and not self.def.title.readonly
  end
end

-- an API error: the parts that name a float go there, all of it into the
-- border and a notification
---@private
function Popup:_api_error(err)
  local by_member, other = model.field_errors(err, self.def.api_fields)
  local bufs = self:_bufs()
  local first
  for member, msg in pairs(by_member) do
    if bufs[member] then
      self:_diagnose(bufs[member], { { lnum = 0, col = 0, message = msg } })
      first = first or member
    end
  end
  local short = other[1] or (first and by_member[first]) or model.message(err)
  self:_set_state("error", short)
  vim.notify(("gg.ui: %s failed: %s"):format(self.def.label, type(err) == "table" and err.message or tostring(err)), vim.log.levels.ERROR)
end

--- `<C-s>`: check, then send. While the checks and the request run the
--- border reads `checking…` / `creating…` and nothing can be edited; an
--- error keeps the popup as it is.
function Popup:submit()
  if self.closed or self.state == "busy" or self._overlay then
    return
  end
  local def = self.def
  local v = self:values()
  for _, buf in pairs(self:_bufs()) do
    vim.diagnostic.reset(self.diag_ns, buf)
  end
  local msg, member
  if def.validate then
    msg, member = def.validate(self, v)
  end
  if not msg and not def.title.readonly and v.title == "" then
    msg, member = "Title cannot be empty", "title"
  end
  if msg then
    vim.cmd("stopinsert")
    return self:fail(msg, member, vim.log.levels.WARN)
  end
  local function go()
    if self.closed then
      return
    end
    self._checking = false
    vim.cmd("stopinsert")
    self:_lock(true)
    self:_set_state("busy")
    self.request = def.submit(self, v)
    self.request:on_done(function(item, err)
      self.request = nil
      if self.closed then
        return
      end
      self:_lock(false)
      if err then
        return self:_api_error(err)
      end
      local ctx = self.ctx
      for _, kind in ipairs(def.changed) do
        ctx.stack:changed(kind)
      end
      ctx.stack:pop()
      def.show(ctx, item)
    end)
  end
  if not def.precheck then
    return go()
  end
  vim.cmd("stopinsert")
  self._checking = true
  self:_lock(true)
  self:_set_state("busy")
  def.precheck(self, v, go, function(message, member)
    if self.closed then
      return
    end
    self._checking = false
    self:_lock(false)
    self:_set_state("idle")
    if message then
      self:fail(message, member)
    end
  end)
end

--- `<Esc><Esc>`: close the popup; asks first when something was changed.
function Popup:cancel()
  if self.closed or self.state == "busy" then
    return
  end
  if not self:dirty() then
    return self.ctx.stack:pop()
  end
  confirm.ask("Discard changes?", function()
    if not self.closed then
      self.ctx.stack:pop()
    end
  end)
end

---@private
function Popup:_teardown()
  if self.closed then
    return
  end
  self.closed = true
  vim.cmd("stopinsert")
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  if self.request then
    pcall(self.request.cancel, self.request)
  end
  for _, t in pairs(self.data) do
    if type(t) == "table" and require("gg").task.is_task(t) then
      pcall(t.cancel, t)
    end
  end
end

return M
