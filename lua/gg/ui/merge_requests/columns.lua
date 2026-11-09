--- Column layout of the merge requests table, in display cells. Pure.
---
--- Body line = <mark 2><! 6><title …>[2 <source 24>][2 <target 8>]
---             [2 <reviewers 17>]<2 assignee 13><2 pipeline 9><2 diff 20>
--- The title takes the rest (minimum 20). Narrower windows hide Target,
--- then Reviewers, then the diff bar (the numbers stay), then Source.
--- The engine is the shared `gg.ui.components.columns`.
local engine = require("gg.ui.components.columns")

local M = {}

M.MARK = 2
M.IID = 6
M.TITLE_MIN = 20
M.SOURCE = 24
M.TARGET = 8
M.REVIEWERS = 17
M.ASSIGNEE = 13
M.PIPELINE = 9
M.DIFF = 20 -- 5 + 1 + 5 + 1 + 8 (bar)
M.DIFF_NUMBERS = 11 -- 5 + 1 + 5
M.GAP = 2

---@class gg.ui.MrColumns
---@field width integer
---@field mark gg.ui.Column
---@field iid gg.ui.Column
---@field title gg.ui.Column
---@field source gg.ui.Column|nil
---@field target gg.ui.Column|nil
---@field reviewers gg.ui.Column|nil
---@field assignee gg.ui.Column
---@field pipeline gg.ui.Column
---@field diff gg.ui.Column `width` is DIFF (with the bar) or DIFF_NUMBERS

M.SPEC = {
  columns = {
    { name = "mark", width = M.MARK },
    { name = "iid", width = M.IID },
    { name = "title", flex = true, min = M.TITLE_MIN },
    { name = "source", width = M.SOURCE, gap = M.GAP },
    { name = "target", width = M.TARGET, gap = M.GAP },
    { name = "reviewers", width = M.REVIEWERS, gap = M.GAP },
    { name = "assignee", width = M.ASSIGNEE, gap = M.GAP },
    { name = "pipeline", width = M.PIPELINE, gap = M.GAP },
    { name = "diff", width = M.DIFF, gap = M.GAP },
  },
  steps = {
    { hide = { "target" } },
    { hide = { "reviewers" } },
    { width = { diff = M.DIFF_NUMBERS } },
    { hide = { "source" } },
  },
}

--- The layout for a window `width` cells wide.
---@param width integer
---@return gg.ui.MrColumns
function M.layout(width)
  return engine.layout(width, M.SPEC)
end

return M
