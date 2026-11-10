--- A strip of nodes joined by segments, with a label and a hint under each
--- node. Pure.
---
---   (✓)━━━━━━━━━━━━━━━(✓)━━━━━━━━━━━━━━━━(◷)───────────────────────(⇣)
---   Pipeline passed    No conflicts      Review · user-2      Merge into main
---                                     waiting for approval          blocked
---
--- Each node owns a slot of the width (the midpoints between node centres);
--- its label and hint are cut to the slot, so they never collide. The first
--- node's texts are left-aligned, the last one's right-aligned, the others
--- centred under their node.
local doc = require("gg.ui.lib.doc")
local line = require("gg.ui.lib.line")
local text = require("gg.ui.lib.text")

local M = {}

M.DONE = "━"
M.TODO = "─"

---@class gg.ui.StripNode
---@field glyph string one cell, e.g. "✓"
---@field hl string the glyph's highlight
---@field done boolean the segment to its right is drawn as done
---@field label string
---@field label_hl? string
---@field hint? gg.ui.Segs

-- node i's left column (the "(")
local function node_col(i, n, width)
  if n == 1 then
    return 0
  end
  return math.floor((i - 1) * (width - 3) / (n - 1))
end

-- the slot [from, to) of node i, by the midpoints between node centres
local function slot(i, n, width)
  local function centre(j)
    return node_col(j, n, width) + 1
  end
  local from = i == 1 and 0 or math.floor((centre(i - 1) + centre(i)) / 2) + 1
  local to = i == n and width or math.floor((centre(i) + centre(i + 1)) / 2)
  return from, to
end

local function segs_width(segs)
  local w = 0
  for _, s in ipairs(segs) do
    w = w + text.width(s[1])
  end
  return w
end

local function cut(segs, max)
  local out, used = {}, 0
  for _, s in ipairs(segs) do
    local w = text.width(s[1])
    if used + w > max then
      if max - used > 0 then
        table.insert(out, { text.truncate(s[1], max - used), s[2] })
      end
      break
    end
    table.insert(out, s)
    used = used + w
  end
  return out
end

-- one line of per-node texts, each placed in its slot
local function texts_line(nodes, width, get, pad)
  local l = line.new():add(pad)
  local base = l.cells
  for i, nd in ipairs(nodes) do
    local segs = get(nd)
    if segs and #segs > 0 then
      local from, to = slot(i, #nodes, width)
      local room = math.max(0, to - from - (i < #nodes and 1 or 0))
      segs = cut(segs, room)
      local w = segs_width(segs)
      local col
      if i == 1 then
        col = from
      elseif i == #nodes then
        col = to - w
      else
        col = math.max(from, math.min(to - w - 1, node_col(i, #nodes, width) + 1 - math.floor(w / 2)))
      end
      l:pad_to(base + col)
      for _, s in ipairs(segs) do
        l:add(s[1], s[2])
      end
    end
  end
  return l
end

--- The strip `width` cells wide (after a `pad` prefix).
---@param nodes gg.ui.StripNode[]
---@param width integer
---@param pad? string default " "
---@return gg.ui.Doc
function M.render(nodes, width, pad)
  pad = pad or " "
  local d = doc.new()
  local n = #nodes
  if n == 0 then
    return d
  end
  width = math.max(n * 4, width)
  local l = line.new():add(pad)
  local base = l.cells
  for i, nd in ipairs(nodes) do
    local col = node_col(i, n, width)
    l:pad_to(base + col)
    l:add("(", "GitlabStripRule"):add(nd.glyph, nd.hl):add(")", "GitlabStripRule")
    if i < n then
      local next_col = node_col(i + 1, n, width)
      local len = next_col - col - 3
      if len > 0 then
        l:add(string.rep(nd.done and M.DONE or M.TODO, len), nd.done and "GitlabStripDone" or "GitlabStripRule")
      end
    end
  end
  d:line(l)
  d:line(texts_line(nodes, width, function(nd)
    return { { nd.label, nd.label_hl or "GitlabStripMuted" } }
  end, pad))
  local hints = texts_line(nodes, width, function(nd)
    return nd.hint
  end, pad)
  if hints.cells > #pad then
    d:line(hints)
  end
  return d
end

--- The strip on one line: "✓ pipeline · ✓ no conflicts · ◷ review · blocked".
---@param nodes gg.ui.StripNode[]
---@param tail? string a last part (e.g. "blocked")
---@return gg.ui.Segs
function M.compact(nodes, tail)
  local out = {}
  for i, nd in ipairs(nodes) do
    if i > 1 then
      table.insert(out, { " · ", "GitlabStripMuted" })
    end
    table.insert(out, { nd.glyph, nd.hl })
    table.insert(out, { " " .. (nd.short or nd.label):lower(), nd.label_hl or "GitlabStripMuted" })
  end
  if tail and tail ~= "" then
    table.insert(out, { " · " .. tail, "GitlabStripMuted" })
  end
  return out
end

return M
