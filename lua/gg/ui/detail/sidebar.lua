--- The sidebar of a detail view: labelled fields. Pure.
---
---   ASSIGNEE
---   (MS) Marius Schaffner
---
---   LABELS
---    WF:Doing   docs
---   ────────────────────
local doc = require("gg.ui.lib.doc")
local line = require("gg.ui.lib.line")
local text = require("gg.ui.lib.text")

local M = {}

M.PAD = 1
M.DIVIDER = "─"

---@class gg.ui.SidebarField
---@field label? string upper-cased when drawn
---@field label_right? string right-aligned on the label line (dim)
---@field lines? gg.ui.Segs[] value lines (each cut to the width)
---@field empty? string shown (dim) when `lines` is empty
---@field divider? boolean a rule instead of a field

--- Draw `fields` into a sidebar `width` cells wide.
---@param fields gg.ui.SidebarField[]
---@param width integer inner width of the sidebar window
---@return gg.ui.Doc
function M.build(fields, width)
  local d = doc.new()
  local pad = string.rep(" ", M.PAD)
  local inner = math.max(1, width - 2 * M.PAD)
  for i, f in ipairs(fields) do
    if i > 1 then
      d:blank()
    end
    if f.divider then
      d:line(line.new():add(pad):add(text.rep(M.DIVIDER, inner), "GitlabDetailDivider"))
    else
      local l = line.new():add(pad):add(text.truncate((f.label or ""):upper(), inner), "GitlabDetailLabel")
      if f.label_right and f.label_right ~= "" then
        local r = text.truncate(f.label_right, math.max(0, inner - l.cells))
        l:pad_to(M.PAD + inner - text.width(r)):add(r, "GitlabDetailMuted")
      end
      d:line(l)
      local lines = f.lines or {}
      if #lines == 0 then
        d:line(line.new():add(pad):add(text.truncate(f.empty or "none", inner), "GitlabDetailMuted"))
      end
      for _, segs in ipairs(lines) do
        d:line(line.new():add(pad):segments(segs, inner))
      end
    end
  end
  return d
end

--- Two values on one line: `left` flush left, `right` flush right.
---@param left gg.ui.Segs
---@param right gg.ui.Segs
---@param width integer inner width (without the sidebar padding)
---@return gg.ui.Segs
function M.spread(left, right, width)
  local lw, rw = 0, 0
  for _, s in ipairs(left) do
    lw = lw + text.width(s[1])
  end
  for _, s in ipairs(right) do
    rw = rw + text.width(s[1])
  end
  local out = vim.list_extend({}, left)
  table.insert(out, { string.rep(" ", math.max(1, width - lw - rw)), nil })
  return vim.list_extend(out, right)
end

--- The inner width of a sidebar `width` cells wide (without padding).
---@param width integer
---@return integer
function M.inner(width)
  return math.max(1, width - 2 * M.PAD)
end

return M
