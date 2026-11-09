--- A one-line prompt buffer: "❯ " prefix, placeholder while empty, an
--- optional right-aligned counter, and a debounced change callback.
local M = {}

---@class gg.ui.PromptOpts
---@field buf integer
---@field prefix? string default "❯ "
---@field placeholder? string default "filter"
---@field debounce_ms? integer default 50
---@field on_change? fun(text: string)

---@class gg.ui.Prompt
---@field buf integer
---@field private _ns integer
---@field private _opts gg.ui.PromptOpts
---@field private _timer uv.uv_timer_t|nil
---@field private _counter string|nil
---@field private _last string
local Prompt = {}
Prompt.__index = Prompt

--- Attach a prompt to `opts.buf` (a scratch buffer).
---@param opts gg.ui.PromptOpts
---@return gg.ui.Prompt
function M.new(opts)
  local self = setmetatable({
    buf = opts.buf,
    _ns = vim.api.nvim_create_namespace("gg.ui.prompt"),
    _opts = opts,
    _timer = vim.uv.new_timer(),
    _last = "",
  }, Prompt)
  vim.bo[self.buf].modifiable = true
  local group = vim.api.nvim_create_augroup(("gg.ui.prompt.%d"):format(self.buf), { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    buffer = self.buf,
    callback = function()
      self:_changed()
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = self.buf,
    callback = function()
      self:destroy()
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  self:_decorate()
  return self
end

--- The current text.
---@return string
function Prompt:text()
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return ""
  end
  return vim.api.nvim_buf_get_lines(self.buf, 0, 1, false)[1] or ""
end

--- Replace the text (fires on_change immediately, no debounce).
---@param s string
function Prompt:set_text(s)
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { s })
  self:_decorate()
  self:_fire()
end

--- Change the placeholder shown while the prompt is empty.
---@param s string
function Prompt:set_placeholder(s)
  self._opts.placeholder = s
  self:_decorate()
end

--- Show `s` right-aligned (nil hides it).
---@param s string|nil
function Prompt:set_counter(s)
  self._counter = s
  self:_decorate()
end

---@private
function Prompt:_changed()
  -- keep a single line (pastes may add more)
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  if #lines > 1 then
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { table.concat(lines, " ") })
  end
  self:_decorate()
  local ms = self._opts.debounce_ms or 50
  if ms <= 0 or not self._timer then
    self:_fire()
    return
  end
  self._timer:stop()
  self._timer:start(ms, 0, vim.schedule_wrap(function()
    self:_fire()
  end))
end

---@private
function Prompt:_fire()
  local s = self:text()
  if s == self._last then
    return
  end
  self._last = s
  if self._opts.on_change then
    self._opts.on_change(s)
  end
end

---@private
function Prompt:_decorate()
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(self.buf, self._ns, 0, -1)
  vim.api.nvim_buf_set_extmark(self.buf, self._ns, 0, 0, {
    virt_text = { { self._opts.prefix or "❯ ", "GitlabPickerPrompt" } },
    virt_text_pos = "inline",
    right_gravity = false,
  })
  if self:text() == "" and (self._opts.placeholder or "filter") ~= "" then
    vim.api.nvim_buf_set_extmark(self.buf, self._ns, 0, 0, {
      virt_text = { { self._opts.placeholder or "filter", "Comment" } },
      virt_text_pos = "eol",
    })
  end
  if self._counter then
    vim.api.nvim_buf_set_extmark(self.buf, self._ns, 0, 0, {
      virt_text = { { self._counter, "Comment" } },
      virt_text_pos = "right_align",
    })
  end
end

--- Stop the debounce timer. Called automatically when the buffer is wiped.
function Prompt:destroy()
  if self._timer then
    self._timer:stop()
    if not self._timer:is_closing() then
      self._timer:close()
    end
    self._timer = nil
  end
end

return M
