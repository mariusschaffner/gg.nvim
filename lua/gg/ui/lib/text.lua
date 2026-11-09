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
