-- Driving the filtered list of `gg.ui.components.select` in tests, by its
-- keys: what it offers, moving to an entry, ticking and taking it.
local H = require("tests.helpers")
local chooser = require("gg.ui.components.select")

local M = {}

local function keys(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "x", false)
end

local function ft_of(win)
  return vim.bo[vim.api.nvim_win_get_buf(win)].filetype
end

--- Wait until a list has the focus; its prompt and list windows.
---@param ft? string filetype prefix (default "gg_ui_select")
---@return integer prompt_win
---@return integer list_win
function M.wait(ft)
  ft = ft or "gg_ui_select"
  H.wait_for(function()
    return ft_of(vim.api.nvim_get_current_win()) == ft .. "_prompt"
  end)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if ft_of(w) == ft .. "_list" then
      return vim.api.nvim_get_current_win(), w
    end
  end
  error("no list window")
end

--- Is a list open (its prompt has the focus)?
---@param ft? string
---@return boolean
function M.is_open(ft)
  return ft_of(vim.api.nvim_get_current_win()) == (ft or "gg_ui_select") .. "_prompt"
end

-- a line without the cursor column and the tick
local function plain(line)
  return (line:gsub("^ " .. chooser.TICK, ""):gsub("^%s+", ""))
end

--- The entries offered, as text; `raw` keeps the ticks.
---@param ft? string
---@param raw? boolean
---@return string[]
function M.offered(ft, raw)
  local _, list = M.wait(ft)
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(list), 0, -1, false)
  return raw and lines or vim.tbl_map(plain, lines)
end

--- Move the cursor to the entry `label` (its text, or what comes before the
--- dimmed note).
---@param label string
---@param ft? string
function M.go(label, ft)
  local _, list = M.wait(ft)
  local offered = M.offered(ft)
  for i, text in ipairs(offered) do
    if text == label or vim.startswith(text, label .. "  ") then
      local at = vim.api.nvim_win_get_cursor(list)[1]
      for _ = 1, (i - at) % #offered do
        keys("<C-n>")
      end
      return
    end
  end
  error(("not offered: %s (%s)"):format(label, table.concat(offered, " | ")))
end

--- Take the entry `label`.
---@param label string
---@param ft? string
function M.choose(label, ft)
  M.go(label, ft)
  keys("<CR>")
end

--- Tick or untick the entry `label` of a multiple choice.
---@param label string
---@param ft? string
function M.toggle(label, ft)
  M.go(label, ft)
  keys("<Tab>")
end

--- Take what is ticked (a multiple choice) or under the cursor.
function M.accept()
  keys("<CR>")
end

--- Dismiss the list.
function M.cancel()
  keys("<Esc>")
end

return M
