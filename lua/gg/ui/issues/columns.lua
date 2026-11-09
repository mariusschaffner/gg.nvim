--- Column layout of the issues table, in display cells. Pure.
---
--- Body line = <edge 2><milestone cell 28><mark 2><iid 6><title …>
---             [gap 2 <labels 32>][gap 2 <assignee 17>]<gap 2><state 10>
--- The title takes the rest (minimum 20). When it would be narrower, Labels
--- is hidden first, then Assignee, then the milestone cell shrinks to 20.
--- The layout engine is the shared `gg.ui.components.columns`.
local engine = require("gg.ui.components.columns")

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

M.SPEC = {
  columns = {
    { name = "edge", width = M.EDGE },
    { name = "milestone", width = M.MILESTONE },
    { name = "mark", width = M.MARK },
    { name = "iid", width = M.IID },
    { name = "title", flex = true, min = M.TITLE_MIN },
    { name = "labels", width = M.LABELS, gap = M.GAP },
    { name = "assignee", width = M.ASSIGNEE, gap = M.GAP },
    { name = "state", width = M.STATE, gap = M.GAP },
  },
  steps = {
    { hide = { "labels" } },
    { hide = { "assignee" } },
    { width = { milestone = M.MILESTONE_MIN } },
  },
}

--- The layout for a window `width` cells wide.
---@param width integer
---@return gg.ui.Columns
function M.layout(width)
  return engine.layout(width, M.SPEC)
end

return M
