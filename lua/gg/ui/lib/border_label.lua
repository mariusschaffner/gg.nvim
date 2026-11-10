--- A left and a right label in one window border. Pure.
---
--- `nvim_open_win` takes one chunk list per border (`title`, `footer`) and
--- one position for it. For "left ───── right" the two labels are joined
--- into a single left-aligned list, with border cells in between that fill
--- the border's width exactly. The fill is drawn in the border's highlight
--- group, so it looks like the border itself.
local text = require("gg.ui.lib.text")

local M = {}

M.RULE = "─"
M.TAIL = 1 -- border cells kept between the right label and the corner

---@param label string|gg.ui.Chunk[]|nil
---@return gg.ui.Chunk[]
local function chunks_of(label)
  if label == nil then
    return {}
  end
  if type(label) == "string" then
    return label ~= "" and { { label } } or {}
  end
  return label
end

--- Display width of a label (a string or chunks).
---@param label string|gg.ui.Chunk[]|nil
---@return integer
function M.width(label)
  local w = 0
  for _, c in ipairs(chunks_of(label)) do
    w = w + text.width(c[1])
  end
  return w
end

-- `chunks` cut to at most `max` cells (the last chunk ends in "…")
local function fit(chunks, max)
  local out, used = {}, 0
  for _, c in ipairs(chunks) do
    local w = text.width(c[1])
    if used + w <= max then
      table.insert(out, c)
      used = used + w
    else
      local rest = text.truncate(c[1], max - used)
      if rest ~= "" then
        table.insert(out, { rest, c[2] })
      end
      break
    end
  end
  return out
end

--- The chunk list for a border of `width` cells (the window's inner width):
--- `left`, border fill, `right`, and `TAIL` border cells before the corner.
--- Without `right` this is just `left`. When both do not fit, the right
--- label goes first, then the left one is cut.
---@param left string|gg.ui.Chunk[]|nil
---@param right string|gg.ui.Chunk[]|nil
---@param width integer
---@param border_hl? string highlight group of the border (default "FloatBorder")
---@return gg.ui.Chunk[]
function M.join(left, right, width, border_hl)
  border_hl = border_hl or "FloatBorder"
  local l, r = chunks_of(left), chunks_of(right)
  local lw, rw = M.width(l), M.width(r)
  if rw == 0 then
    return fit(l, math.max(0, width))
  end
  local fill = width - lw - rw - M.TAIL
  if fill < 1 then
    -- no room for both: the left label alone
    return fit(l, math.max(0, width))
  end
  local out = {}
  vim.list_extend(out, l)
  table.insert(out, { text.rep(M.RULE, fill), border_hl })
  vim.list_extend(out, r)
  table.insert(out, { text.rep(M.RULE, M.TAIL), border_hl })
  return out
end

return M
