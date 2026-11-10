--- Display-width text helpers. Pure.
---
--- Everything is measured in display cells (`strdisplaywidth`), never bytes:
--- the UI uses multi-byte glyphs (━ ● ✓ … ▎ ▌ ─ ❯) and titles can hold
--- wide characters.
local M = {}

M.ELLIPSIS = "…"

--- Display width of `s`.
---@param s string
---@return integer
function M.width(s)
  return vim.fn.strdisplaywidth(s)
end

--- `s` on one line: control characters (newlines, tabs, ...) become spaces.
---@param s string|nil
---@return string
function M.clean(s)
  if s == nil then
    return ""
  end
  return (tostring(s):gsub("%c", " "))
end

--- The longest prefix of `s` that fits in `max` cells.
---@param s string
---@param max integer
---@return string prefix
---@return integer width of the prefix
local function fit_prefix(s, max)
  local n = vim.fn.strchars(s)
  local out, w = {}, 0
  for i = 0, n - 1 do
    local ch = vim.fn.strcharpart(s, i, 1)
    local cw = M.width(ch)
    if w + cw > max then
      break
    end
    out[#out + 1] = ch
    w = w + cw
  end
  return table.concat(out), w
end

--- Truncate `s` to at most `max` display cells, ending in "…" when cut.
---@param s string
---@param max integer
---@return string
function M.truncate(s, max)
  if max <= 0 then
    return ""
  end
  if M.width(s) <= max then
    return s
  end
  local ell = M.width(M.ELLIPSIS)
  if max <= ell then
    return (fit_prefix(M.ELLIPSIS, max))
  end
  return (fit_prefix(s, max - ell)) .. M.ELLIPSIS
end

--- `s` truncated to `width` cells and padded with spaces to exactly `width`.
---@param s string
---@param width integer
---@return string
function M.pad(s, width)
  s = M.truncate(s, width)
  local w = M.width(s)
  if w < width then
    s = s .. string.rep(" ", width - w)
  end
  return s
end

-- split `word` into pieces of at most `width` cells
local function hard_split(word, width)
  local out = {}
  while M.width(word) > width do
    local piece = fit_prefix(word, width)
    if piece == "" then
      break
    end
    table.insert(out, piece)
    word = word:sub(#piece + 1)
  end
  table.insert(out, word)
  return out
end

--- Word-wrap one line of text into lines of at most `width` cells. Runs of
--- spaces between words collapse to one; leading indentation is kept on the
--- first line. Words longer than `width` are split. An empty string gives
--- one empty line.
---@param s string
---@param width integer
---@return string[]
function M.wrap(s, width)
  s = M.clean(s)
  width = math.max(1, width)
  local indent = s:match("^( *)")
  local words = {}
  for w in s:gmatch("%S+") do
    table.insert(words, w)
  end
  if #words == 0 then
    return { "" }
  end
  if M.width(indent) >= width then
    indent = ""
  end
  local out, cur, cur_w = {}, indent, M.width(indent)
  local fresh = true -- nothing but the indent on the current line
  for _, w in ipairs(words) do
    local ww = M.width(w)
    if not fresh and cur_w + 1 + ww > width then
      table.insert(out, cur)
      cur, cur_w, fresh = "", 0, true
    end
    if fresh and cur_w + ww > width then
      local pieces = hard_split(w, width - cur_w)
      for i = 1, #pieces - 1 do
        table.insert(out, cur .. pieces[i])
        cur, cur_w = "", 0
      end
      w, ww = pieces[#pieces], M.width(pieces[#pieces])
    end
    if fresh then
      cur, cur_w = cur .. w, cur_w + ww
    else
      cur, cur_w = cur .. " " .. w, cur_w + 1 + ww
    end
    fresh = false
  end
  table.insert(out, cur)
  return out
end

--- `s` repeated to fill exactly `width` cells (for rules like "─").
---@param s string a one-cell glyph
---@param width integer
---@return string
function M.rep(s, width)
  if width <= 0 then
    return ""
  end
  return string.rep(s, width)
end

return M
