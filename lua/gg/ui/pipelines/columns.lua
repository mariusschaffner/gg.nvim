--- Column layout of the pipelines table, in display cells. Pure.
---
--- Body line = <mark 2><status 11><2 # N><2 ref 27><2 mr 6><2 commit …>
---             <2 source 10><2 stages 9><2 started 8>
--- The commit takes the rest (minimum 20). The `#` column is as wide as the
--- longest loaded "#id" (at least ID_MIN; gitlab.com ids have 10 digits).
--- Narrower windows hide MR, then Source, then shorten Ref, then hide Ref,
--- then Started. The engine is the shared `gg.ui.components.columns`.
local engine = require("gg.ui.components.columns")

local M = {}

M.MARK = 2
M.STATUS = 11 -- "⊘ canceling"; with the gap the spec's 13
M.ID_MIN = 6
M.REF = 27
M.REF_SHORT = 14
M.MR = 6
M.COMMIT_MIN = 20
M.SOURCE = 10
M.STAGES = 9
M.STARTED = 8
M.GAP = 2

---@class gg.ui.PipelineColumns
---@field width integer
---@field mark gg.ui.Column
---@field status gg.ui.Column
---@field id gg.ui.Column
---@field ref gg.ui.Column|nil
---@field mr gg.ui.Column|nil
---@field commit gg.ui.Column
---@field source gg.ui.Column|nil
---@field stages gg.ui.Column
---@field started gg.ui.Column|nil

--- The layout spec for an `#` column `id_width` cells wide.
---@param id_width? integer
---@return gg.ui.LayoutSpec
function M.spec(id_width)
  return {
    columns = {
      { name = "mark", width = M.MARK },
      { name = "status", width = M.STATUS },
      { name = "id", width = math.max(M.ID_MIN, id_width or 0), gap = M.GAP },
      { name = "ref", width = M.REF, gap = M.GAP },
      { name = "mr", width = M.MR, gap = M.GAP },
      { name = "commit", flex = true, min = M.COMMIT_MIN, gap = M.GAP },
      { name = "source", width = M.SOURCE, gap = M.GAP },
      { name = "stages", width = M.STAGES, gap = M.GAP },
      { name = "started", width = M.STARTED, gap = M.GAP },
    },
    steps = {
      { hide = { "mr" } },
      { hide = { "source" } },
      { width = { ref = M.REF_SHORT } },
      { hide = { "ref" } },
      { hide = { "started" } },
    },
  }
end

--- The width of the `#` column for these pipelines ("#" + the longest id).
---@param pipelines gg.Pipeline[]
---@return integer
function M.id_width(pipelines)
  local w = M.ID_MIN
  for _, p in ipairs(pipelines) do
    w = math.max(w, #tostring(p.id or "") + 1)
  end
  return w
end

--- The layout for a window `width` cells wide.
---@param width integer
---@param id_width? integer
---@return gg.ui.PipelineColumns
function M.layout(width, id_width)
  return engine.layout(width, M.spec(id_width))
end

return M
