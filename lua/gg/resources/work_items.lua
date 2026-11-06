--- Work items: issue start and due dates.
---
--- Backend: GraphQL only (`namespace.workItem` and the `workItemUpdate`
--- mutation); REST has no start-date field for issues.
local common = require("gg.resources.common")
local graphql = require("gg.graphql.client")
local task = require("gg.core.task")
local work_item = require("gg.models.work_item")

local M = {}

local function load_dates(host, project, iid)
  return task.run(function()
    local path, perr = graphql.project_path(host, project):await()
    if not path then
      return nil, perr
    end
    local data, err = graphql.query(host, "work_item_dates", { fullPath = path, iid = tostring(iid) }):await()
    if err then
      return nil, err
    end
    local node, nerr = graphql.require(data, "namespace.workItem", ("work item %s#%s"):format(path, tostring(iid)))
    if not node then
      return nil, nerr
    end
    return work_item.dates_from_graphql(node)
  end)
end

--- Start and due dates of an issue (work item).
---@param args { host: string, project: string|integer, iid: integer }
---@return gg.Task resolves with gg.WorkItemDates
function M.dates(args)
  return common.run(args, { host = "host", project = "project", iid = "id" }, function()
    return load_dates(args.host, args.project, args.iid):await()
  end)
end

---@class gg.WorkItemUpdateDatesArgs
---@field host string
---@field project string|integer
---@field iid integer
---@field start_date? string|false YYYY-MM-DD, or false to clear it
---@field due_date? string|false YYYY-MM-DD, or false to clear it
---@field work_item_id? string the work item's global ID, if known (saves a lookup)

--- Set or clear an issue's start and due dates. Dates that are not given
--- are left as they are.
---@param args gg.WorkItemUpdateDatesArgs
---@return gg.Task resolves with the updated gg.WorkItemDates
function M.update_dates(args)
  local spec = {
    host = "host",
    project = "project",
    iid = "id",
    start_date = "date_or_false?",
    due_date = "date_or_false?",
    work_item_id = "string?",
  }
  local err = common.check(args, spec)
  if err then
    return task.failed(err)
  end
  if args.start_date == nil and args.due_date == nil then
    return task.failed(common.invalid("start_date", "or args.due_date is required: nothing to update"))
  end
  return task.run(function()
    local id = args.work_item_id
    if not id then
      local current, lerr = load_dates(args.host, args.project, args.iid):await()
      if not current then
        return nil, lerr
      end
      id = current.work_item_id
    end
    local vars = { id = id }
    -- an explicit null clears a date; an absent variable leaves it alone
    if args.start_date ~= nil then
      vars.startDate = args.start_date == false and vim.NIL or args.start_date
    end
    if args.due_date ~= nil then
      vars.dueDate = args.due_date == false and vim.NIL or args.due_date
    end
    local data, qerr = graphql.query(args.host, "work_item_update_dates", vars):await()
    if qerr then
      return nil, qerr
    end
    local payload = data.workItemUpdate
    local perr = graphql.payload_error(payload, "WorkItemUpdateDates")
    if perr then
      return nil, perr
    end
    local node, nerr = graphql.require(data, "workItemUpdate.workItem", "updated work item")
    if not node then
      return nil, nerr
    end
    return work_item.dates_from_graphql(node)
  end)
end

return M
