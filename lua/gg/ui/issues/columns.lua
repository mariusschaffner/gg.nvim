--- Column layout of the issues table, in display cells. Pure.
---
--- Body line = <edge 2><milestone cell 28><mark 2><iid 6><title …>
---             [gap 2 <labels 32>][gap 2 <assignee 17>]<gap 2><state 10>
--- The title takes the rest (minimum 20). When it would be narrower, Labels
--- is hidden first, then Assignee, then the milestone cell shrinks to 20.
local M = {}

M.EDGE = 2
M.MILESTONE = 28
M.MILESTONE_MIN = 20
M.MARK = 2
M.IID = 6
M.LABELS = 32
M.ASSIGNEE = 17
M.STATE = 10
M.GAP = 2
M.TITLE_MIN = 20

---@class gg.ui.Column
---@field col integer 0-based display column
---@field width integer

---@class gg.ui.Columns
---@field width integer the whole line
---@field edge gg.ui.Column
---@field milestone gg.ui.Column the cell; its text gets `width - GAP`
---@field mark gg.ui.Column
---@field iid gg.ui.Column
---@field title gg.ui.Column
---@field labels gg.ui.Column|nil hidden on narrow windows
---@field assignee gg.ui.Column|nil hidden on narrow windows
---@field state gg.ui.Column

local function fixed(labels, assignee, ms)
  return M.EDGE
    + ms
    + M.MARK
    + M.IID
    + (labels and (M.GAP + M.LABELS) or 0)
    + (assignee and (M.GAP + M.ASSIGNEE) or 0)
    + M.GAP
    + M.STATE
end

--- The layout for a window `width` cells wide.
---@param width integer
---@return gg.ui.Columns
function M.layout(width)
  local tries = {
    { true, true, M.MILESTONE },
    { false, true, M.MILESTONE },
    { false, false, M.MILESTONE },
    { false, false, M.MILESTONE_MIN },
  }
  local pick = tries[#tries]
  for _, t in ipairs(tries) do
    if width - fixed(t[1], t[2], t[3]) >= M.TITLE_MIN then
      pick = t
      break
    end
  end
  local show_labels, show_assignee, ms = pick[1], pick[2], pick[3]
  local title_w = math.max(M.TITLE_MIN, width - fixed(show_labels, show_assignee, ms))

  local c = { width = width }
  local x = 0
  local function take(w)
    local col = { col = x, width = w }
    x = x + w
    return col
  end
  c.edge = take(M.EDGE)
  c.milestone = take(ms)
  c.mark = take(M.MARK)
  c.iid = take(M.IID)
  c.title = take(title_w)
  if show_labels then
    x = x + M.GAP
    c.labels = take(M.LABELS)
  end
  if show_assignee then
    x = x + M.GAP
    c.assignee = take(M.ASSIGNEE)
  end
  x = x + M.GAP
  c.state = take(M.STATE)
  return c
end

return M
