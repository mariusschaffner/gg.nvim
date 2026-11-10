--- The variables editor in the body of the run pipeline popup: one
--- `KEY = value` line per variable (see `gg.ui.create.variables`).
---
--- * A header row (`Key = Value … Type`) sits above the lines in the
---   window bar, so it is never part of the text.
--- * Every line has a type, `var` or `file`, drawn right-aligned. It is
---   kept in an extmark on the line, so it stays with its line through
---   edits; `t` toggles it.
--- * `a` adds `‹KEY› = ‹value›` below the cursor and selects the key.
--- * Lines that still hold a default of the CI configuration say so.
local placeholders = require("gg.ui.create.placeholders")
local variables = require("gg.ui.create.variables")

local M = {}

M.DEFAULT_NOTE = "default from .gitlab-ci.yml"
M.HEADER = "%#GitlabColumnHeader# Key = Value%=Type "

---@class gg.ui.VariablesView
---@field p gg.ui.CreatePopup
---@field buf integer
---@field win integer
---@field types table<integer, "var"|"file"> extmark id -> type
---@field defaults table<string, true> the lines that are untouched defaults
local View = {}
View.__index = View

--- Attach the editor to popup `p`'s body.
---@param p gg.ui.CreatePopup
---@return gg.ui.VariablesView
function M.attach(p)
  local self = setmetatable({
    p = p,
    buf = p.body_float.buf,
    win = p.body_float.win,
    types = {},
    defaults = {},
    ns = vim.api.nvim_create_namespace("gg.ui.create.variables"),
    note_ns = vim.api.nvim_create_namespace("gg.ui.create.variables.notes"),
  }, View)
  vim.api.nvim_set_option_value("winbar", M.HEADER, { win = self.win })
  vim.api.nvim_set_option_value("wrap", false, { win = self.win })
  p:map_body(p.keys.add_variable, function()
    self:add()
  end, "Add a variable")
  p:map_body(p.keys.toggle_variable_type, function()
    self:toggle()
  end, "Variable ⇄ file")
  p:on_change(function(member)
    if member == "body" then
      self:sync()
    end
  end)
  self:sync()
  return self
end

local function lines_of(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- Bring the type marks in line with the text: one per non-blank line,
--- none on blank ones; then redraw them, the default notes and the count.
function View:sync()
  local buf = self.buf
  if self.p.closed or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = lines_of(buf)
  local by_row = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, self.ns, 0, -1, { details = true })) do
    local id, row, details = m[1], m[2], m[4]
    local blank = vim.trim(lines[row + 1] or "") == ""
    -- its line is gone, or a second mark ended up on a line (a join)
    if details.invalid or blank or by_row[row] then
      vim.api.nvim_buf_del_extmark(buf, self.ns, id)
      self.types[id] = nil
    else
      by_row[row] = id
    end
  end
  for row, line in ipairs(lines) do
    if vim.trim(line) ~= "" then
      self:_mark(row - 1, by_row[row - 1])
    end
  end
  vim.api.nvim_buf_clear_namespace(buf, self.note_ns, 0, -1)
  for row, line in ipairs(lines) do
    if self.defaults[line] then
      vim.api.nvim_buf_set_extmark(buf, self.note_ns, row - 1, 0, { virt_text = { { "  " .. M.DEFAULT_NOTE, "GitlabCreateDim" } }, virt_text_pos = "eol" })
    end
  end
  self.p:set_entity(("Variables · %d"):format(variables.count(lines)))
end

-- create or redraw the type mark of 0-based `row`
---@private
function View:_mark(row, id)
  local kind = id and self.types[id] or "var"
  local new = vim.api.nvim_buf_set_extmark(self.buf, self.ns, row, 0, {
    id = id,
    -- the whole line: when it is deleted the mark goes with it
    end_row = row + 1,
    end_col = 0,
    invalidate = true,
    strict = false,
    virt_text = { { kind, kind == "file" and "GitlabCreateKey" or "Comment" } },
    virt_text_pos = "right_align",
  })
  self.types[new] = kind
  return new
end

--- The type of every non-blank line: 1-based line -> "var" | "file".
---@return table<integer, string>
function View:line_types()
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(self.buf, self.ns, 0, -1, { details = true })) do
    if not m[4].invalid then
      out[m[2] + 1] = self.types[m[1]] or "var"
    end
  end
  return out
end

--- `t`: variable ⇄ file for the line under the cursor.
function View:toggle()
  local row = vim.api.nvim_win_get_cursor(self.win)[1] - 1
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(self.buf, self.ns, { row, 0 }, { row, -1 }, { details = true })) do
    if not m[4].invalid then
      self.types[m[1]] = self.types[m[1]] == "file" and "var" or "file"
      self:_mark(row, m[1])
      return
    end
  end
end

--- `a`: a new `‹KEY› = ‹value›` line below the cursor (in place of an
--- empty buffer), with the key selected.
function View:add()
  if not vim.bo[self.buf].modifiable then
    return
  end
  local lines = lines_of(self.buf)
  local row
  if #lines == 1 and vim.trim(lines[1]) == "" then
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { variables.NEW_LINE })
    row = 1
  else
    row = vim.api.nvim_win_get_cursor(self.win)[1] + 1
    vim.api.nvim_buf_set_lines(self.buf, row - 1, row - 1, false, { variables.NEW_LINE })
  end
  self:sync()
  local span = placeholders.find({ variables.NEW_LINE })[1]
  span.row = row
  self.p:select(self.win, span)
end

--- Fill the editor with the variables the CI configuration declares (their
--- defaults), unless something was written already.
---@param list gg.CiConfigVariable[]
---@return boolean filled
function View:set_defaults(list)
  local lines = lines_of(self.buf)
  if self.p.closed or #list == 0 or self.p:dirty() or variables.count(lines) > 0 then
    return false
  end
  local out = {}
  self.defaults = {}
  for _, v in ipairs(list) do
    local line = variables.line(v.key, v.value)
    table.insert(out, line)
    self.defaults[line] = true
  end
  self.p:set_body(out)
  self:sync()
  return true
end

return M
