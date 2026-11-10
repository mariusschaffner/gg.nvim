--- A rounded floating window over a scratch buffer.
local M = {}

---@class gg.ui.FloatSpec
---@field rect gg.ui.Rect
---@field title? string|gg.ui.Chunk[]
---@field footer? string|gg.ui.Chunk[]
---@field enter? boolean focus the window (default false)
---@field buf? integer use this buffer instead of a new scratch buffer
---@field filetype? string
---@field win_opts? table<string, any> window-local options
---@field zindex? integer default 50
---@field focusable? boolean default true
---@field hide? boolean open hidden (default false)
---@field border? string|string[] default "rounded"

---@class gg.ui.Float
---@field win integer
---@field buf integer

--- A new scratch buffer (not listed, wiped when hidden).
---@param filetype? string
---@return integer
function M.scratch(filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buftype = "nofile"
  if filetype then
    vim.bo[buf].filetype = filetype
  end
  return buf
end

local function win_config(spec)
  local cfg = {
    relative = "editor",
    row = spec.rect.row,
    col = spec.rect.col,
    width = spec.rect.width,
    height = spec.rect.height,
    border = spec.border or "rounded",
    style = "minimal",
    zindex = spec.zindex or 50,
    focusable = spec.focusable ~= false,
    hide = spec.hide == true,
  }
  if spec.title then
    cfg.title = spec.title
    cfg.title_pos = "left"
  end
  if spec.footer then
    cfg.footer = spec.footer
    cfg.footer_pos = "left"
  end
  return cfg
end

--- Open a float.
---@param spec gg.ui.FloatSpec
---@return gg.ui.Float
function M.open(spec)
  local buf = spec.buf or M.scratch(spec.filetype)
  local win = vim.api.nvim_open_win(buf, spec.enter == true, win_config(spec))
  for k, v in pairs(spec.win_opts or {}) do
    vim.api.nvim_set_option_value(k, v, { win = win })
  end
  return { win = win, buf = buf }
end

--- Move/resize a float and optionally change its title or footer.
---@param win integer
---@param rect gg.ui.Rect
---@param extra? { title?: string|gg.ui.Chunk[], footer?: string|gg.ui.Chunk[], hide?: boolean, border?: string|string[], focusable?: boolean }
function M.update(win, rect, extra)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  extra = extra or {}
  local cfg = win_config({
    rect = rect,
    title = extra.title,
    footer = extra.footer,
    hide = extra.hide,
    border = extra.border,
    focusable = extra.focusable,
  })
  cfg.style = nil -- "minimal" can only be set when the window is created
  cfg.zindex = nil -- keep the window's own
  -- the title and footer stay unless given (a border change would drop them)
  if not extra.title then
    cfg.title = nil
  end
  if not extra.footer then
    cfg.footer = nil
  end
  vim.api.nvim_win_set_config(win, cfg)
end

--- Hide or show a float (Neovim 0.10 `hide`), keeping everything else.
---@param win integer
---@param hidden boolean
function M.set_hidden(win, hidden)
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, { hide = hidden })
  end
end

--- Set the title and/or footer of a float, keeping its geometry.
---@param win integer
---@param opts { title?: string|gg.ui.Chunk[], footer?: string|gg.ui.Chunk[] }
function M.set_text(win, opts)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  -- title/footer need the border in the same call
  local cfg = { border = "rounded" }
  if opts.title then
    cfg.title = opts.title
    cfg.title_pos = "left"
  end
  if opts.footer then
    cfg.footer = opts.footer
    cfg.footer_pos = "left"
  end
  if cfg.title or cfg.footer then
    vim.api.nvim_win_set_config(win, cfg)
  end
end

return M
