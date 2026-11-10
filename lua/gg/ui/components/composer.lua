--- A comment composer: a bordered markdown float laid over the Activity tab
--- (docked at its bottom for a new comment, under a thread for a reply, over
--- a comment for an edit). It grows with its text, shows a placeholder while
--- empty and "● unsaved" once changed, and completes `@` mentions.
---
--- `submit` (`<C-s>`) posts, `submit_resolve` (`<C-r>`) posts and resolves
--- (replies to a resolvable thread), `cancel_edit` (`<Esc>` in normal mode)
--- or leaving the window cancels.
local hint = require("gg.ui.lib.hint")

local M = {}

M.MIN_HEIGHT = 3
M.MAX_HEIGHT = 10

---@class gg.ui.ComposerOpts
---@field win integer the window the composer is laid over
---@field place { bottom: true }|{ bufpos: integer }|nil docked at the bottom, or below buffer line `bufpos` (0-based)
---@field col? integer columns from the window's left edge (default 0)
---@field width integer
---@field text? string seed
---@field title string e.g. "Comment", "Reply to thread"
---@field placeholder? string
---@field keys gg.ui.Keymaps
---@field resolve? boolean offer "post & resolve"
---@field mentions? fun(): gg.ui.Candidate[] usernames to complete after "@"
---@field on_submit fun(text: string, resolve: boolean, done: fun(ok: boolean))
---@field on_close fun(posted: boolean)
---@field group? gg.ui.FloatGroup

---@class gg.ui.Composer
---@field win integer
---@field buf integer
---@field closed boolean
local Composer = {}
Composer.__index = Composer

local function lhs(k)
  return require("gg.ui.components.picker").lhs_list(k)
end

local function first(k)
  return require("gg.ui.components.picker").first_key(k)
end

--- Open the composer (it takes the focus, in insert mode).
---@param opts gg.ui.ComposerOpts
---@return gg.ui.Composer
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  local seed = opts.text or ""
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(seed, "\n", { plain = true }))
  local self = setmetatable({ buf = buf, opts = opts, seed = seed, closed = false, saving = false }, Composer)
  local cfg = self:_config(M.MIN_HEIGHT)
  cfg.style = "minimal"
  cfg.border = "rounded"
  cfg.zindex = 150
  cfg.title = { { " " .. opts.title .. " ", "GitlabPickerTitle" } }
  cfg.title_pos = "left"
  cfg.footer = self:_footer()
  cfg.footer_pos = "left"
  self.win = vim.api.nvim_open_win(buf, true, cfg)
  vim.api.nvim_set_option_value("winhighlight", "FloatBorder:GitlabDetailBorderEditing,NormalFloat:Normal", { win = self.win })
  vim.api.nvim_set_option_value("wrap", true, { win = self.win })
  vim.api.nvim_set_option_value("linebreak", true, { win = self.win })
  if opts.group then
    opts.group:allow(self.win)
  end
  self.ns = vim.api.nvim_create_namespace("gg.ui.composer")
  local function map(modes, k, fn)
    for _, l in ipairs(lhs(k)) do
      vim.keymap.set(modes, l, fn, { buffer = buf, nowait = true, silent = true })
    end
  end
  map({ "n", "i" }, opts.keys.submit, function()
    self:submit(false)
  end)
  if opts.resolve then
    map({ "n", "i" }, opts.keys.submit_resolve, function()
      self:submit(true)
    end)
  end
  map("n", opts.keys.cancel_edit, function()
    self:cancel()
  end)
  self.augroup = vim.api.nvim_create_augroup(("gg.ui.composer.%d"):format(self.win), { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = self.augroup,
    buffer = buf,
    callback = function(ev)
      self:_changed()
      if ev.event == "TextChangedI" then
        self:_mention()
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = self.augroup,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if not self.closed and not self.saving and vim.api.nvim_get_current_win() ~= self.win then
          self:cancel()
        end
      end)
    end,
  })
  self:_changed()
  local last = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_win_set_cursor(self.win, { last, #(vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or "") })
  vim.cmd("startinsert!")
  return self
end

-- the window config for `height` text rows
---@private
function Composer:_config(height)
  local o = self.opts
  local cfg = { relative = "win", win = o.win, width = math.max(20, o.width - 2), height = height, col = o.col or 0 }
  if o.place and o.place.bufpos then
    -- starts on the line below `bufpos`
    cfg.bufpos = { o.place.bufpos, 0 }
    cfg.row = 1
  else
    local wh = vim.api.nvim_win_get_height(o.win)
    cfg.row = math.max(0, wh - height - 2)
  end
  return cfg
end

---@private
function Composer:_footer()
  local o = self.opts
  local hints = { { key = first(o.keys.submit), desc = "Post" } }
  if o.resolve then
    table.insert(hints, { key = first(o.keys.submit_resolve), desc = "Post & resolve" })
  end
  table.insert(hints, { key = first(o.keys.cancel_edit), desc = "Cancel" })
  local chunks = hint.chunks(vim.tbl_filter(function(h)
    return h.key ~= nil
  end, hints))
  if self.dirty then
    table.insert(chunks, { "● unsaved ", "GitlabDetailBorderEditing" })
  end
  return chunks
end

--- The text.
---@return string
function Composer:text()
  return table.concat(vim.api.nvim_buf_get_lines(self.buf, 0, -1, false), "\n")
end

-- grow with the text, the placeholder, the unsaved mark
---@private
function Composer:_changed()
  if self.closed or not vim.api.nvim_win_is_valid(self.win) then
    return
  end
  local text = self:text()
  local n = vim.api.nvim_buf_line_count(self.buf)
  local h = math.max(M.MIN_HEIGHT, math.min(M.MAX_HEIGHT, n))
  local cfg = self:_config(h)
  local dirty = text ~= self.seed
  local footer_changed = dirty ~= self.dirty
  self.dirty = dirty
  if footer_changed then
    cfg.footer = self:_footer()
    cfg.footer_pos = "left"
  end
  pcall(vim.api.nvim_win_set_config, self.win, cfg)
  vim.api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)
  if text == "" and self.opts.placeholder then
    vim.api.nvim_buf_set_extmark(self.buf, self.ns, 0, 0, {
      virt_text = { { self.opts.placeholder, "GitlabEditPlaceholder" } },
      virt_text_pos = "overlay",
    })
  end
end

-- "@us" before the cursor: offer the matching usernames
---@private
function Composer:_mention()
  if not self.opts.mentions then
    return
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(self.win))
  local line = vim.api.nvim_buf_get_lines(self.buf, row - 1, row, false)[1] or ""
  local at, query = line:sub(1, col):match("()@([%w%._%-]*)$")
  if not at then
    return
  end
  local items = require("gg.ui.detail.edits").match(query, self.opts.mentions())
  self.last_items = items
  if #items > 0 and vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    vim.fn.complete(at + 1, vim.tbl_map(function(c)
      return { word = c.word, menu = c.menu }
    end, items))
  end
end

---@private
function Composer:_finish(posted)
  if self.closed then
    return
  end
  self.closed = true
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  if self.opts.group then
    self.opts.group:allow(self.win, false)
  end
  vim.cmd("stopinsert")
  if vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  self.opts.on_close(posted)
end

--- Post (and resolve). Empty text is refused.
---@param resolve boolean
function Composer:submit(resolve)
  if self.closed or self.saving then
    return
  end
  local text = vim.trim(self:text())
  if text == "" then
    vim.notify("gg.ui: the comment is empty", vim.log.levels.WARN)
    return
  end
  self.saving = true
  vim.cmd("stopinsert")
  self.opts.on_submit(text, resolve == true, function(ok)
    self.saving = false
    if ok then
      self:_finish(true)
    end
  end)
end

--- Close without posting.
function Composer:cancel()
  if not self.saving then
    self:_finish(false)
  end
end

return M
