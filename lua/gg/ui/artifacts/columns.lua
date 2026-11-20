--- Column layout of the artifacts tree, in display cells. Pure.
---
--- Body line = <mark 2><name …><2 size 10><2 expires 10>
--- Name takes the rest (at least NAME_MIN). Narrow windows hide Expires,
--- then Size. The engine is the shared `gg.ui.components.columns`.
local engine = require("gg.ui.components.columns")

local M = {}

M.MARK = 2
M.NAME_MIN = 30
M.SIZE = 10
M.EXPIRES = 10
M.GAP = 2

---@class gg.ui.ArtifactColumns
---@field width integer
---@field mark gg.ui.Column
---@field name gg.ui.Column
---@field size gg.ui.Column|nil
---@field expires gg.ui.Column|nil

--- The layout spec.
---@return gg.ui.LayoutSpec
function M.spec()
  return {
    columns = {
      { name = "mark", width = M.MARK },
      { name = "name", flex = true, min = M.NAME_MIN },
      { name = "size", width = M.SIZE, gap = M.GAP },
      { name = "expires", width = M.EXPIRES, gap = M.GAP },
    },
    steps = {
      { hide = { "expires" } },
      { hide = { "size" } },
    },
  }
end

--- The layout for a window `width` cells wide.
---@param width integer
---@return gg.ui.ArtifactColumns
function M.layout(width)
  return engine.layout(width, M.spec())
end

return M
