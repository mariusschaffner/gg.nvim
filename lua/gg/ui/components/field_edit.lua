--- A one-line editor laid over a field (a title, a sidebar value, a date):
--- a borderless float in the field's place, seeded with its current text.
---
--- `submit` (`<C-s>`) or `<CR>` saves, `cancel_edit` (`<Esc>` in normal
--- mode) or leaving the window cancels. With `complete`, candidates for the
--- value at the cursor come up while typing (debounced) and on
--- `complete_next` / `complete_prev` (`<Tab>` / `<S-Tab>`), which also step
--- through them. Multi-value fields are comma-separated.
local edits = require("gg.ui.detail.edits")

local M = {}

M.DEBOUNCE_MS = 150
M.MIN_WIDTH = 24

---@class gg.ui.FieldEditOpts
---@field row integer 0-based editor row
---@field col integer 0-based editor column
---@field width integer
---@field text string the current value
---@field multi? boolean comma-separated values
---@field keys gg.ui.Keymaps
---@field complete? fun(query: string, cb: fun(items: gg.ui.Candidate[])) candidates for the value being typed
---@field on_save fun(text: string, done: fun(ok: boolean)) keep editing unless done(true)
---@field on_close fun(saved: boolean)
---@field group? gg.ui.FloatGroup the view's windows (the overlay may take the focus)

---@class gg.ui.FieldEdit
---@field win integer
---@field buf integer
---@field closed boolean
---@field last_items gg.ui.Candidate[]|nil the last candidates offered (tests)
local Field = {}
Field.__index = Field

local function keys_of(k)
  return require("gg.ui.components.picker").lhs_list(k)
end

--- Open the overlay (it takes the focus, in insert mode at the end).
---@param opts gg.ui.FieldEditOpts
---@return gg.ui.FieldEdit
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  local text = tostring(opts.text or ""):gsub("[\r\n]", " ")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  local width = math.max(M.MIN_WIDTH, opts.width)
  width = math.min(width, math.max(1, vim.o.columns - opts.col - 1))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = opts.row,
    col = opts.col,
    width = width,
    height = 1,
    style = "minimal",
    border = "none",
    zindex = 200,
  })
  vim.api.nvim_set_option_value("winhighlight", "Normal:GitlabFieldEdit", { win = win })
  vim.api.nvim_set_option_value("wrap", false, { win = win })
  local self = setmetatable({ win = win, buf = buf, opts = opts, closed = false, saving = false }, Field)
  if opts.group then
    opts.group:allow(win)
  end
  local function map(modes, k, fn, o)
    for _, lhs in ipairs(type(k) == "string" and { k } or keys_of(k)) do
      vim.keymap.set(modes, lhs, fn, vim.tbl_extend("force", { buffer = buf, nowait = true, silent = true }, o or {}))
    end
  end
  map({ "n", "i" }, opts.keys.submit, function()
    self:save()
  end)
  map("n", opts.keys.cancel_edit, function()
    self:cancel()
  end)
  map("n", "<CR>", function()
    self:save()
  end)
  map("i", "<CR>", function()
    if vim.fn.pumvisible() == 1 then
      return "<C-y>"
    end
    vim.schedule(function()
      self:save()
    end)
    return ""
  end, { expr = true })
  map("i", opts.keys.complete_next, function()
    if vim.fn.pumvisible() == 1 then
      return "<C-n>"
    end
    vim.schedule(function()
      self:complete_now()
    end)
    return ""
  end, { expr = true })
  map("i", opts.keys.complete_prev, function()
    return vim.fn.pumvisible() == 1 and "<C-p>" or ""
  end, { expr = true })
  self.augroup = vim.api.nvim_create_augroup(("gg.ui.field.%d"):format(win), { clear = true })
  if opts.complete then
    vim.api.nvim_create_autocmd("TextChangedI", {
      group = self.augroup,
      buffer = buf,
      callback = function()
        self:_debounce()
      end,
    })
  end
  vim.api.nvim_create_autocmd("WinLeave", {
    group = self.augroup,
    buffer = buf,
    callback = function()
      -- the completion menu does not leave the window; anything else cancels
      vim.schedule(function()
        if not self.closed and not self.saving and vim.api.nvim_get_current_win() ~= self.win then
          self:cancel()
        end
      end)
    end,
  })
  vim.api.nvim_win_set_cursor(win, { 1, #text })
  vim.cmd("startinsert!")
  return self
end

--- The current text.
---@return string
function Field:text()
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return ""
  end
  return (vim.api.nvim_buf_get_lines(self.buf, 0, 1, false)[1] or "")
end

---@private
function Field:_debounce()
  if self.timer then
    self.timer:stop()
  else
    self.timer = vim.uv.new_timer()
  end
  self.timer:start(M.DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    self:complete_now()
  end))
end

--- Ask for the candidates of the value at the cursor and offer them.
function Field:complete_now()
  if self.closed or not self.opts.complete then
    return
  end
  local line = self:text()
  local col = vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_get_cursor(self.win)[2] or #line
  if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
    col = #line
  end
  local start, query = edits.token(line, col, self.opts.multi == true)
  local typed = self.opts.multi and edits.split(line:sub(1, start)) or {}
  self.opts.complete(query, function(items)
    if self.closed then
      return
    end
    items = edits.match(query, items or {}, typed)
    self.last_items = items
    if #items > 0 and vim.api.nvim_get_current_win() == self.win and vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
      vim.fn.complete(start + 1, vim.tbl_map(function(c)
        return { word = c.word, menu = c.menu, dup = 0 }
      end, items))
    end
  end)
end

---@private
function Field:_finish(saved)
  if self.closed then
    return
  end
  self.closed = true
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  if self.opts.group then
    self.opts.group:allow(self.win, false)
  end
  vim.cmd("stopinsert")
  if vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  self.opts.on_close(saved)
end

--- Save the text (`on_save` decides whether the overlay closes).
function Field:save()
  if self.closed or self.saving then
    return
  end
  self.saving = true
  vim.cmd("stopinsert")
  self.opts.on_save(vim.trim(self:text()), function(ok)
    self.saving = false
    if ok then
      self:_finish(true)
    elseif vim.api.nvim_win_is_valid(self.win) then
      vim.api.nvim_set_current_win(self.win)
    end
  end)
end

--- Close without saving.
function Field:cancel()
  if not self.saving then
    self:_finish(false)
  end
end

return M
