--- A small list with a filter for choosing a branch or tag: a one-line
--- prompt and the matches below it. Typing asks for the matches again
--- (debounced); `<C-n>` / `<C-p>` or the arrows move, `<CR>` picks, `<Esc>`
--- or leaving the prompt cancels.
---
--- When the floats cannot be opened (an editor too small for them), the
--- choice goes through `vim.ui.select`.
local float = require("gg.ui.components.float")
local prompt = require("gg.ui.components.prompt")

local M = {}

M.MAX_ROWS = 10
M.MIN_WIDTH = 30
M.ICONS = { branch = "⎇", tag = "◆" }

---@class gg.ui.RefItem
---@field name string
---@field kind "branch"|"tag"
---@field sha? string
---@field title? string the commit title
---@field default? boolean the project's default branch

---@class gg.ui.RefPickerOpts
---@field title string the prompt's border title ("Source branch")
---@field row integer 0-based editor row of the prompt float (outer)
---@field col integer 0-based editor column (outer)
---@field width integer outer width
---@field load fun(query: string, cb: fun(items: gg.ui.RefItem[])) the matches for `query`
---@field on_pick fun(item: gg.ui.RefItem)
---@field on_close? fun(picked: boolean)
---@field group? gg.ui.FloatGroup the windows the picker belongs to (it may take the focus)
---@field debounce_ms? integer default 120

---@class gg.ui.RefPicker
---@field prompt_float gg.ui.Float
---@field list_float gg.ui.Float
---@field items gg.ui.RefItem[]
---@field index integer the selected item (0 without items)
---@field closed boolean
local Picker = {}
Picker.__index = Picker

--- One line of the list: icon, name and, dimmed, the short SHA and commit title.
---@param item gg.ui.RefItem
---@return string line
---@return { [1]: integer, [2]: integer, [3]: string }[] marks byte ranges and their groups
function M.line(item)
  local head = (" %s %s"):format(M.ICONS[item.kind] or " ", item.name)
  local note = M.note(item)
  local marks = { { 0, #head, item.kind == "tag" and "GitlabRefTag" or (item.default and "GitlabRefDefault" or "GitlabBranchSource") } }
  if note == "" then
    return head, marks
  end
  local line = head .. "  " .. note
  table.insert(marks, { #head, #line, "GitlabCreateDim" })
  return line, marks
end

--- "1a2b3c4d  the commit title" (what is known of it).
---@param item gg.ui.RefItem
---@return string
function M.note(item)
  local parts = {}
  if item.sha then
    table.insert(parts, item.sha:sub(1, 8))
  end
  if item.title and item.title ~= "" then
    table.insert(parts, item.title)
  end
  return table.concat(parts, "  ")
end

local function select_fallback(opts)
  opts.load("", function(items)
    vim.ui.select(items, {
      prompt = opts.title,
      format_item = function(item)
        return item.name
      end,
    }, function(item)
      if item then
        opts.on_pick(item)
      end
      if opts.on_close then
        opts.on_close(item ~= nil)
      end
    end)
  end)
end

--- Open the picker (the prompt takes the focus, in insert mode). Returns
--- nil when it fell back to `vim.ui.select`.
---@param opts gg.ui.RefPickerOpts
---@return gg.ui.RefPicker|nil
function M.open(opts)
  local area = { columns = vim.o.columns, lines = vim.o.lines - vim.o.cmdheight }
  local width = math.max(M.MIN_WIDTH, opts.width)
  local col = math.max(0, math.min(opts.col, area.columns - width))
  local rows = math.min(M.MAX_ROWS, area.lines - opts.row - 5)
  if rows < 1 or width > area.columns then
    select_fallback(opts)
    return nil
  end
  local self = setmetatable({ opts = opts, items = {}, index = 0, closed = false, seq = 0 }, Picker)
  self.ns = vim.api.nvim_create_namespace("gg.ui.ref_picker")
  local ok, err = pcall(function()
    self.list_float = float.open({
      rect = { row = opts.row + 3, col = col, width = width - 2, height = rows },
      zindex = 210,
      focusable = false,
      filetype = "gg_ui_ref_list",
      win_opts = { wrap = false, cursorline = false, number = false, signcolumn = "no" },
    })
    self.prompt_float = float.open({
      rect = { row = opts.row, col = col, width = width - 2, height = 1 },
      title = (" %s "):format(opts.title),
      zindex = 210,
      enter = true,
      filetype = "gg_ui_ref_prompt",
      win_opts = { wrap = false },
    })
  end)
  if not ok then
    self:_close_windows()
    vim.notify("gg.ui: " .. tostring(err), vim.log.levels.DEBUG)
    select_fallback(opts)
    return nil
  end
  for _, f in ipairs({ self.list_float, self.prompt_float }) do
    vim.api.nvim_set_option_value("winhighlight", "FloatBorder:GitlabPickerBorderActive,FloatTitle:GitlabPickerTitle", { win = f.win })
    if opts.group then
      opts.group:allow(f.win)
    end
  end
  vim.bo[self.list_float.buf].modifiable = false
  self.prompt = prompt.new({
    buf = self.prompt_float.buf,
    placeholder = "filter",
    debounce_ms = opts.debounce_ms or 120,
    on_change = function(q)
      self:_load(q)
    end,
  })
  local buf = self.prompt_float.buf
  local function map(modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  for _, lhs in ipairs({ "<C-n>", "<Down>" }) do
    map({ "i", "n" }, lhs, function()
      self:move(1)
    end)
  end
  for _, lhs in ipairs({ "<C-p>", "<Up>" }) do
    map({ "i", "n" }, lhs, function()
      self:move(-1)
    end)
  end
  map("n", "j", function()
    self:move(1)
  end)
  map("n", "k", function()
    self:move(-1)
  end)
  map({ "i", "n" }, "<CR>", function()
    self:pick()
  end)
  map({ "i", "n" }, "<Esc>", function()
    self:close(false)
  end)
  map("n", "q", function()
    self:close(false)
  end)
  self.augroup = vim.api.nvim_create_augroup(("gg.ui.ref_picker.%d"):format(buf), { clear = true })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = self.augroup,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if not self.closed and vim.api.nvim_get_current_win() ~= self.prompt_float.win then
          self:close(false)
        end
      end)
    end,
  })
  self.loading = true
  self:_render()
  self:_load("")
  vim.cmd("startinsert!")
  return self
end

---@private
function Picker:_load(query)
  self.seq = self.seq + 1
  local seq = self.seq
  self.loading = true
  self.opts.load(query, function(items)
    -- a later query was typed meanwhile: its answer wins
    if self.closed or seq ~= self.seq then
      return
    end
    self.loading = false
    self.items = items or {}
    self.index = #self.items > 0 and 1 or 0
    self:_render()
  end)
end

---@private
function Picker:_render()
  local buf = self.list_float.buf
  if self.closed or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines, marks = {}, {}
  for i, item in ipairs(self.items) do
    local line, m = M.line(item)
    lines[i] = line
    marks[i] = m
  end
  if #lines == 0 then
    lines = { self.loading and " Loading…" or " No matches" }
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, self.ns, 0, -1)
  for i, ms in ipairs(marks) do
    for _, m in ipairs(ms) do
      vim.api.nvim_buf_set_extmark(buf, self.ns, i - 1, m[1], { end_col = m[2], hl_group = m[3] })
    end
  end
  if #self.items == 0 then
    vim.api.nvim_buf_set_extmark(buf, self.ns, 0, 0, { end_col = #lines[1], hl_group = "GitlabCreateDim" })
  else
    vim.api.nvim_buf_set_extmark(buf, self.ns, self.index - 1, 0, { line_hl_group = "GitlabCursorLine" })
    vim.api.nvim_buf_set_extmark(buf, self.ns, self.index - 1, 0, { virt_text = { { "▌", "GitlabCursorMark" } }, virt_text_pos = "overlay" })
    pcall(vim.api.nvim_win_set_cursor, self.list_float.win, { self.index, 0 })
  end
  self.prompt:set_counter(#self.items > 0 and tostring(#self.items) or nil)
end

--- Move the selection by `dir`, wrapping around.
---@param dir integer
function Picker:move(dir)
  if self.closed or #self.items == 0 then
    return
  end
  self.index = (self.index - 1 + dir) % #self.items + 1
  self:_render()
end

--- Take the selected item.
function Picker:pick()
  local item = self.items[self.index]
  if self.closed or not item then
    return
  end
  self:close(true)
  self.opts.on_pick(item)
end

---@private
function Picker:_close_windows()
  for _, f in ipairs({ self.prompt_float, self.list_float }) do
    if f and vim.api.nvim_win_is_valid(f.win) then
      if self.opts.group then
        self.opts.group:allow(f.win, false)
      end
      pcall(vim.api.nvim_win_close, f.win, true)
    end
  end
end

--- Close the picker.
---@param picked? boolean
function Picker:close(picked)
  if self.closed then
    return
  end
  self.closed = true
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  if self.prompt then
    self.prompt:destroy()
  end
  vim.cmd("stopinsert")
  self:_close_windows()
  if self.opts.on_close then
    self.opts.on_close(picked == true)
  end
end

return M
