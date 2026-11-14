--- A small list with a filter for choosing one or several of something: a
--- one-line prompt and the matches below it. Typing asks for the matches
--- again (debounced); `<C-n>` / `<C-p>` or the arrows move, `<CR>` picks,
--- `<Esc>` or leaving the prompt cancels. With `multi`, `<Tab>` ticks the
--- item under the cursor and `<CR>` takes everything ticked.
---
--- When the floats cannot be opened (an editor too small for them), a single
--- choice goes through `vim.ui.select`; a `multi` one is refused.
local float = require("gg.ui.components.float")
local float_group = require("gg.ui.components.float_group")
local hint = require("gg.ui.lib.hint")
local prompt = require("gg.ui.components.prompt")

local M = {}

M.MAX_ROWS = 10
M.MIN_WIDTH = 30
M.TICK = "✓"

---@alias gg.ui.SelectMark { [1]: integer, [2]: integer, [3]: string } a byte range and its highlight group

---@class gg.ui.SelectOpts
---@field title string the prompt's border title ("Source branch")
---@field row integer 0-based editor row of the prompt float (outer)
---@field col integer 0-based editor column (outer)
---@field width integer outer width
---@field load fun(query: string, cb: fun(items: any[])) the matches for `query`
---@field line fun(item: any): string, gg.ui.SelectMark[]|nil one line of the list (it starts with a space, for the cursor mark)
---@field text? fun(item: any): string the item for `vim.ui.select` (default: its line, trimmed)
---@field on_pick fun(picked: any) the item; with `multi`, the list of ticked items
---@field on_close? fun(picked: boolean)
---@field multi? boolean tick several items
---@field key? fun(item: any): string what makes two items the same one (`multi`, `current`)
---@field selected? any[] the items ticked at first (`multi`)
---@field current? string the key of the item the cursor starts on
---@field fit? boolean shrink the list to the matches (default: always `max_rows` high)
---@field group? gg.ui.FloatGroup the windows the picker belongs to (it may take the focus)
---@field debounce_ms? integer default 120
---@field max_rows? integer default `MAX_ROWS`
---@field min_width? integer default `MIN_WIDTH`
---@field placeholder? string default "filter"
---@field filetype? string prefix of the buffers' filetypes (default "gg_ui_select": `_prompt`, `_list`)

---@class gg.ui.Select
---@field prompt_float gg.ui.Float
---@field list_float gg.ui.Float
---@field items any[]
---@field index integer the item under the cursor (0 without items)
---@field closed boolean
local Picker = {}
Picker.__index = Picker

--- A `load` over a fixed list: the items whose `text(item)` contains the
--- query (case-insensitive), those starting with it first.
---@generic T
---@param items T[]
---@param text fun(item: T): string
---@return fun(query: string, cb: fun(items: T[]))
function M.static(items, text)
  return function(query, cb)
    local q = vim.trim(query):lower()
    if q == "" then
      return cb(vim.list_slice(items))
    end
    local pre, sub = {}, {}
    for _, it in ipairs(items) do
      local t = text(it):lower()
      if vim.startswith(t, q) then
        table.insert(pre, it)
      elseif t:find(q, 1, true) then
        table.insert(sub, it)
      end
    end
    cb(vim.list_extend(pre, sub))
  end
end

--- Where a picker goes that belongs to no field: centred in the editor.
---@param count integer the number of items (the list's height, up to `MAX_ROWS`)
---@param width? integer outer width (default 60)
---@return { row: integer, col: integer, width: integer }
function M.centered(count, width)
  local columns, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight
  width = math.max(M.MIN_WIDTH, math.min(width or 60, columns - 4))
  local height = 3 + math.max(1, math.min(count, M.MAX_ROWS)) + 2
  return { row = math.max(0, math.floor((lines - height) / 2)), col = math.max(0, math.floor((columns - width) / 2)), width = width }
end

local function text_of(opts, item)
  if opts.text then
    return opts.text(item)
  end
  return vim.trim((opts.line(item)))
end

local function fallback(opts)
  if opts.multi then
    vim.notify(("gg.ui: No room to choose: %s"):format(opts.title), vim.log.levels.WARN)
    if opts.on_close then
      opts.on_close(false)
    end
    return
  end
  opts.load("", function(items)
    -- a prompt drawn by a plugin may take the focus: keep the screen open
    local release = float_group.hold()
    vim.ui.select(items, {
      prompt = opts.title,
      format_item = function(item)
        return text_of(opts, item)
      end,
    }, function(item)
      release()
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
---@param opts gg.ui.SelectOpts
---@return gg.ui.Select|nil
function M.open(opts)
  local area = { columns = vim.o.columns, lines = vim.o.lines - vim.o.cmdheight }
  local width = math.max(opts.min_width or M.MIN_WIDTH, opts.width)
  local col = math.max(0, math.min(opts.col, area.columns - width))
  local row = math.max(0, opts.row)
  local rows = math.min(opts.max_rows or M.MAX_ROWS, area.lines - row - 5)
  if rows < 1 or width > area.columns then
    fallback(opts)
    return nil
  end
  local ft = opts.filetype or "gg_ui_select"
  local self = setmetatable({ opts = opts, items = {}, index = 0, closed = false, seq = 0, rows = rows, ticked = {}, order = {} }, Picker)
  for _, item in ipairs(opts.selected or {}) do
    self:_tick(item, true)
  end
  self.ns = vim.api.nvim_create_namespace("gg.ui.select")
  self.list_rect = { row = row + 3, col = col, width = width - 2, height = rows }
  local ok, err = pcall(function()
    self.list_float = float.open({
      rect = self.list_rect,
      footer = opts.multi and hint.chunks({ { key = "<Tab>", desc = "Toggle" }, { key = "<CR>", desc = "Apply" } }) or nil,
      zindex = 210,
      focusable = false,
      filetype = ft .. "_list",
      win_opts = { wrap = false, cursorline = false, number = false, signcolumn = "no" },
    })
    self.prompt_float = float.open({
      rect = { row = row, col = col, width = width - 2, height = 1 },
      title = (" %s "):format(opts.title),
      zindex = 210,
      enter = true,
      filetype = ft .. "_prompt",
      win_opts = { wrap = false },
    })
  end)
  if not ok then
    self:_close_windows()
    vim.notify("gg.ui: " .. tostring(err), vim.log.levels.DEBUG)
    fallback(opts)
    return nil
  end
  for _, f in ipairs({ self.list_float, self.prompt_float }) do
    vim.api.nvim_set_option_value("winhighlight", "FloatBorder:GitlabPickerBorderActive,FloatTitle:GitlabPickerTitle,FloatFooter:GitlabPickerFooter", { win = f.win })
    if opts.group then
      opts.group:allow(f.win)
    end
  end
  vim.bo[self.list_float.buf].modifiable = false
  self.prompt = prompt.new({
    buf = self.prompt_float.buf,
    placeholder = opts.placeholder or "filter",
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
  if opts.multi then
    map({ "i", "n" }, "<Tab>", function()
      self:toggle()
    end)
  end
  map({ "i", "n" }, "<CR>", function()
    self:pick()
  end)
  map({ "i", "n" }, "<Esc>", function()
    self:close(false)
  end)
  map("n", "q", function()
    self:close(false)
  end)
  self.augroup = vim.api.nvim_create_augroup(("gg.ui.select.%d"):format(buf), { clear = true })
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
function Picker:_key(item)
  if self.opts.key then
    return self.opts.key(item)
  end
  return text_of(self.opts, item)
end

-- tick or untick `item`, keeping the order in which things were ticked
---@private
function Picker:_tick(item, on)
  local key = self:_key(item)
  if on and not self.ticked[key] then
    table.insert(self.order, key)
  elseif not on and self.ticked[key] then
    for i, k in ipairs(self.order) do
      if k == key then
        table.remove(self.order, i)
        break
      end
    end
  end
  self.ticked[key] = on and item or nil
end

--- The ticked items, in the order they were ticked (`multi`).
---@return any[]
function Picker:selection()
  return vim.tbl_map(function(key)
    return self.ticked[key]
  end, self.order)
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
    -- the first answer: start on the current value
    if not self.started and self.opts.current then
      for i, item in ipairs(self.items) do
        if self:_key(item) == self.opts.current then
          self.index = i
          break
        end
      end
    end
    self.started = true
    self:_render()
  end)
end

---@private
function Picker:_render()
  local buf = self.list_float.buf
  if self.closed or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local multi = self.opts.multi
  local lines, marks = {}, {}
  for i, item in ipairs(self.items) do
    local line, m = self.opts.line(item)
    m = m or {}
    if multi then
      -- " ✓" before the line, which brings its own leading space
      local on = self.ticked[self:_key(item)] ~= nil
      local head = " " .. (on and M.TICK or " ")
      local shifted = { { 0, #head, "GitlabSelectTick" } }
      for _, mark in ipairs(m) do
        table.insert(shifted, { mark[1] + #head, mark[2] + #head, mark[3] })
      end
      line, m = head .. line, shifted
    end
    lines[i] = line
    marks[i] = m
  end
  if #lines == 0 then
    lines = { self.loading and " Loading…" or " No matches" }
  end
  if self.opts.fit and not self.loading and vim.api.nvim_win_is_valid(self.list_float.win) then
    local height = math.max(1, math.min(#lines, self.rows))
    if height ~= self.list_rect.height then
      self.list_rect.height = height
      float.update(self.list_float.win, self.list_rect)
    end
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
  local counter = #self.items > 0 and tostring(#self.items) or nil
  if multi then
    counter = ("%d %s"):format(#self.order, M.TICK) .. (counter and ("  " .. counter) or "")
  end
  self.prompt:set_counter(counter)
end

--- Move the cursor by `dir`, wrapping around.
---@param dir integer
function Picker:move(dir)
  if self.closed or #self.items == 0 then
    return
  end
  self.index = (self.index - 1 + dir) % #self.items + 1
  self:_render()
end

--- Tick or untick the item under the cursor and move on (`multi`).
function Picker:toggle()
  local item = self.items[self.index]
  if self.closed or not self.opts.multi or not item then
    return
  end
  self:_tick(item, self.ticked[self:_key(item)] == nil)
  if self.index < #self.items then
    self.index = self.index + 1
  end
  self:_render()
end

--- Take the item under the cursor; with `multi`, everything ticked.
function Picker:pick()
  if self.closed then
    return
  end
  local picked
  if self.opts.multi then
    if self.loading and not self.started then
      return
    end
    picked = self:selection()
  else
    picked = self.items[self.index]
    if not picked then
      return
    end
  end
  self:close(true)
  self.opts.on_pick(picked)
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
