--- Work item dates (issue start and due dates). Pure.
local util = require("gg.models.util")

local M = {}

---@class gg.WorkItemDates
---@field work_item_id string GraphQL global ID of the work item (needed to update it)
---@field iid integer
---@field start_date string|nil YYYY-MM-DD
---@field due_date string|nil YYYY-MM-DD

--- Map a GraphQL WorkItem node selected with the START_AND_DUE_DATE widget.
---@param node table|nil
---@return gg.WorkItemDates|nil
function M.dates_from_graphql(node)
  node = util.value(node)
  if type(node) ~= "table" then
    return nil
  end
  local widget = {}
  for _, w in ipairs(util.value(node.widgets) or {}) do
    if w.type == "START_AND_DUE_DATE" then
      widget = w
    end
  end
  return {
    work_item_id = util.value(node.id),
    iid = tonumber(util.value(node.iid)),
    start_date = util.date(widget.startDate),
    due_date = util.date(widget.dueDate),
  }
end

return M
