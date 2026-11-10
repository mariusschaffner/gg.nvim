--- Creation popups: new issue, new merge request, new milestone, run
--- pipeline. One popup (`gg.ui.create.popup`), one definition per view
--- (`gg.ui.create.defs.*`).
---
--- Each one is pushed onto the picker's stack. After a successful submit
--- the popup gives way to the detail view of what was created; `q` there
--- goes back to the screen the popup was opened from.
local M = {}

local function push(ctx, name, preset)
  return ctx.stack:push(function(stack)
    local c = vim.tbl_extend("force", {}, ctx, { stack = stack })
    return require("gg.ui.create.popup").open(c, require("gg.ui.create.defs." .. name), preset).screen
  end)
end

--- New issue. `preset.milestone_id` and `preset.labels` are sent along
--- without being shown.
---@param ctx gg.ui.DetailCtx
---@param preset? { title?: string, description?: string, milestone_id?: integer, labels?: string[] }
---@return gg.ui.Screen|nil
function M.issue(ctx, preset)
  return push(ctx, "issue", preset)
end

--- New merge request. Without `preset.source_branch` the source is the
--- current git branch of `preset.cwd` (default: the working directory);
--- without `preset.target_branch` the target is the project's default branch.
---@param ctx gg.ui.DetailCtx
---@param preset? { source_branch?: string, target_branch?: string, title?: string, description?: string, cwd?: string }
---@return gg.ui.Screen|nil
function M.merge_request(ctx, preset)
  return push(ctx, "merge_request", preset)
end

--- New milestone.
---@param ctx gg.ui.DetailCtx
---@param preset? { title?: string, description?: string, start_date?: string, due_date?: string }
---@return gg.ui.Screen|nil
function M.milestone(ctx, preset)
  return push(ctx, "milestone", preset)
end

--- Run a pipeline. Without `preset.ref` the ref is the current git branch
--- of `preset.cwd` when GitLab has it, else the project's default branch.
---@param ctx gg.ui.DetailCtx
---@param preset? { ref?: string, cwd?: string }
---@return gg.ui.Screen|nil
function M.pipeline(ctx, preset)
  return push(ctx, "pipeline", preset)
end

return M
