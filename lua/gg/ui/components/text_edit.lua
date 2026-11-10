--- Edit a text in place: a markdown buffer with the raw text takes the
--- place of a tab's buffer in its window until the edit ends. `submit`
--- (`<C-s>`, normal and insert mode) saves, `cancel_edit` (`<Esc>` in normal
--- mode) cancels; the window shows the tab again afterwards.
---
--- Only these two keys are mapped in the edit buffer, so the view's own keys
--- (`i`, `x`, `q`, the tab keys) cannot fire while editing.
local M = {}

---@class gg.ui.TextEditOpts
---@field win integer the window to edit in
---@field text string
---@field cursor? integer line to start on (default 1)
---@field filetype? string default "markdown"
---@field keys gg.ui.Keymaps
---@field insert? boolean start in insert mode (default true)
---@field on_save fun(text: string, done: fun(ok: boolean)) keep editing unless done(true)
---@field on_close fun(saved: boolean) the window shows its buffer again

---@class gg.ui.TextEdit
---@field buf integer
---@field win integer
---@field closed boolean
---@field saving boolean
local Edit = {}
Edit.__index = Edit

local function map(buf, modes, k, fn, desc)
  for _, lhs in ipairs(require("gg.ui.components.picker").lhs_list(k)) do
    vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
end

local WIN_OPTS = { wrap = true, linebreak = true, cursorline = false, number = false, spell = false }

--- Start editing.
---@param opts gg.ui.TextEditOpts
---@return gg.ui.TextEdit
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = opts.filetype or "markdown"
  local lines = vim.split((opts.text or ""):gsub("\r", ""), "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  local self = setmetatable({
    buf = buf,
    win = opts.win,
    prev = vim.api.nvim_win_get_buf(opts.win),
    opts = opts,
    closed = false,
    saving = false,
    saved_opts = {},
  }, Edit)
  for o in pairs(WIN_OPTS) do
    self.saved_opts[o] = vim.api.nvim_get_option_value(o, { win = opts.win })
  end
  vim.api.nvim_win_set_buf(opts.win, buf)
  for o, v in pairs(WIN_OPTS) do
    vim.api.nvim_set_option_value(o, v, { win = opts.win })
  end
  pcall(vim.api.nvim_win_set_cursor, opts.win, { math.max(1, math.min(#lines, opts.cursor or 1)), 0 })
  map(buf, { "n", "i" }, opts.keys.submit, function()
    self:save()
  end, "Save")
  map(buf, "n", opts.keys.cancel_edit, function()
    self:cancel()
  end, "Cancel")
  if opts.insert ~= false then
    vim.cmd("startinsert")
  end
  return self
end

--- The text being edited.
---@return string
function Edit:text()
  return table.concat(vim.api.nvim_buf_get_lines(self.buf, 0, -1, false), "\n")
end

---@private
function Edit:_finish(saved)
  if self.closed then
    return
  end
  self.closed = true
  vim.cmd("stopinsert")
  if vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_buf_is_valid(self.prev) then
    vim.api.nvim_win_set_buf(self.win, self.prev)
    for o, v in pairs(self.saved_opts) do
      vim.api.nvim_set_option_value(o, v, { win = self.win })
    end
  end
  if vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end
  self.opts.on_close(saved)
end

--- Save: `on_save` decides whether the edit ends.
function Edit:save()
  if self.closed or self.saving then
    return
  end
  self.saving = true
  vim.cmd("stopinsert")
  self.opts.on_save(self:text(), function(ok)
    self.saving = false
    if ok then
      self:_finish(true)
    end
  end)
end

--- Cancel: the text is dropped.
function Edit:cancel()
  if not self.saving then
    self:_finish(false)
  end
end

return M
