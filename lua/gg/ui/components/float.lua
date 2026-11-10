--- A rounded floating window over a scratch buffer.
---
--- A border can carry a left and a right label: `title` + `title_right`,
--- `footer` + `footer_right` (see `gg.ui.lib.border_label`). The two are
--- joined for the window's width, so they are rebuilt whenever it changes;
--- `gg.ui.components.float_group` does that for its members.
local border_label = require("gg.ui.lib.border_label")

local M = {}

---@class gg.ui.FloatSpec
---@field rect gg.ui.Rect
---@field title? string|gg.ui.Chunk[]
---@field footer? string|gg.ui.Chunk[]
---@field title_right? string|gg.ui.Chunk[] a second label at the right end of the top border
---@field footer_right? string|gg.ui.Chunk[] a second label at the right end of the bottom border
---@field label_hl? string the border's highlight group, for the fill between two labels (default "FloatBorder")
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

-- one border's text: the label alone, or left + fill + right for `width`
local function border_text(left, right, width, hl)
  if right == nil then
    return left
  end
  local chunks = border_label.join(left, right, width, hl)
  return #chunks > 0 and chunks or ""
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
  if spec.title or spec.title_right then
    cfg.title = border_text(spec.title, spec.title_right, spec.rect.width, spec.label_hl)
    cfg.title_pos = "left"
  end
  if spec.footer or spec.footer_right then
    cfg.footer = border_text(spec.footer, spec.footer_right, spec.rect.width, spec.label_hl)
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
---@param extra? { title?: string|gg.ui.Chunk[], footer?: string|gg.ui.Chunk[], title_right?: string|gg.ui.Chunk[], footer_right?: string|gg.ui.Chunk[], label_hl?: string, hide?: boolean, border?: string|string[], focusable?: boolean }
function M.update(win, rect, extra)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  extra = extra or {}
  local cfg = win_config({
    rect = rect,
    title = extra.title,
    footer = extra.footer,
    title_right = extra.title_right,
    footer_right = extra.footer_right,
    label_hl = extra.label_hl,
    hide = extra.hide,
    border = extra.border,
    focusable = extra.focusable,
  })
  cfg.style = nil -- "minimal" can only be set when the window is created
  cfg.zindex = nil -- keep the window's own
  -- the title and footer stay unless given (a border change would drop them)
  if not (extra.title or extra.title_right) then
    cfg.title = nil
  end
  if not (extra.footer or extra.footer_right) then
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

--- Set the title and/or footer of a float, keeping its geometry. With
--- `title_right` / `footer_right` the border gets a left and a right label,
--- joined for the window's current width.
---@param win integer
---@param opts { title?: string|gg.ui.Chunk[], footer?: string|gg.ui.Chunk[], title_right?: string|gg.ui.Chunk[], footer_right?: string|gg.ui.Chunk[], label_hl?: string }
function M.set_text(win, opts)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  -- title/footer need the border in the same call
  local cfg = { border = "rounded" }
  local width = vim.api.nvim_win_get_width(win)
  if opts.title or opts.title_right then
    cfg.title = border_text(opts.title, opts.title_right, width, opts.label_hl)
    cfg.title_pos = "left"
  end
  if opts.footer or opts.footer_right then
    cfg.footer = border_text(opts.footer, opts.footer_right, width, opts.label_hl)
    cfg.footer_pos = "left"
  end
  if cfg.title or cfg.footer then
    vim.api.nvim_win_set_config(win, cfg)
  end
end

return M
