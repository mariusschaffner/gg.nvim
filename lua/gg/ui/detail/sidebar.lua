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
---@field id? string names the value lines as a region (`doc.regions[id]`)
---@field ids? string[] several names for the same value lines (e.g. both dates)
---@field line_ids? table<string, integer> names for single value lines (index into `lines`)
---@field hint? string|false a key, shown right-aligned as "[key]" on the label line
---@field editing? boolean the field is being edited: its label turns orange
---@field label_segs? gg.Segs the label line's left part instead of `label` (e.g. two dates)
---@field right_segs? gg.Segs the label line's right part instead of `label_right` / `hint`

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
      local label_hl = f.editing and "GitlabDetailLabelEditing" or "GitlabDetailLabel"
      local l = line.new():add(pad)
      if f.label_segs then
        for _, sg in ipairs(f.label_segs) do
          l:add(sg[1], sg[2] or label_hl)
        end
      else
        l:add(text.truncate((f.label or ""):upper(), inner), label_hl)
      end
      local right = f.right_segs
      if not right then
        right = {}
        if f.label_right and f.label_right ~= "" then
          table.insert(right, { f.label_right, "GitlabDetailMuted" })
        end
        if f.hint then
          if #right > 0 then
            table.insert(right, { " ", nil })
          end
          table.insert(right, { "[" .. f.hint .. "]", "GitlabHintKey" })
        end
      end
      if #right > 0 then
        local rw = 0
        for _, sg in ipairs(right) do
          rw = rw + text.width(sg[1])
        end
        l:pad_to(M.PAD + math.max(l.cells - M.PAD + 1, inner - rw))
        for _, sg in ipairs(right) do
          l:add(sg[1], sg[2] or label_hl)
        end
      end
      d:line(l)
      local first = d:count() + 1
      local lines = f.lines or {}
      if #lines == 0 then
        d:line(line.new():add(pad):add(text.truncate(f.empty or "none", inner), "GitlabDetailMuted"))
      end
      for _, segs in ipairs(lines) do
        d:line(line.new():add(pad):segments(segs, inner))
      end
      for _, id in ipairs(f.ids or (f.id and { f.id }) or {}) do
        d:region(id, first, #pad, inner, d:count() - first + 1)
      end
      for id, idx in pairs(f.line_ids or {}) do
        d:region(id, first + idx - 1, #pad, inner)
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
