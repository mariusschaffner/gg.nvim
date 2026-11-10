--- Detail views: issue, milestone, merge request and pipeline.
---
--- Each one is pushed onto the picker's stack (`gg.ui.components.stack`);
--- `q` goes back to the screen below, `Q` closes everything. Detail views
--- open each other through the same functions, so every jump can be undone
--- with `q`.
local M = {}

---@class gg.ui.DetailCtx
---@field stack gg.ui.Stack
---@field cfg gg.ui.Config
---@field host string
---@field project string full path of the project the item belongs to
---@field now? fun(): integer epoch seconds (tests)
---@field today? gg.ui.Date (tests)

local function push(ctx, module, item)
  return ctx.stack:push(function(stack)
    local c = vim.tbl_extend("force", {}, ctx, { stack = stack })
    return require(module).open(c, item).screen
  end)
end

--- Open the detail view of `issue` (a full or partial `gg.Issue`; `iid` is
--- required, `project` overrides the context's project).
---@param ctx gg.ui.DetailCtx
---@param issue gg.Issue|{ iid: integer, project?: string }
---@return gg.ui.Screen|nil
function M.issue(ctx, issue)
  return push(ctx, "gg.ui.detail.issue.view", issue)
end

--- Open the detail view of `milestone` (`id` is required).
---@param ctx gg.ui.DetailCtx
---@param milestone gg.MilestoneRef|gg.Milestone
---@return gg.ui.Screen|nil
function M.milestone(ctx, milestone)
  return push(ctx, "gg.ui.detail.milestone.view", milestone)
end

--- Open the detail view of merge request `mr` (`iid` is required).
---@param ctx gg.ui.DetailCtx
---@param mr gg.MergeRequest|{ iid: integer, project?: string }
---@return gg.ui.Screen|nil
function M.merge_request(ctx, mr)
  return push(ctx, "gg.ui.detail.merge_request.view", mr)
end

--- Open the detail view of `pipeline` (`id` is required).
---@param ctx gg.ui.DetailCtx
---@param pipeline gg.Pipeline|{ id: integer, project?: string }
---@return gg.ui.Screen|nil
function M.pipeline(ctx, pipeline)
  return push(ctx, "gg.ui.detail.pipeline.view", pipeline)
end

return M
