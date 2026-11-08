--- Merge readiness checks of a merge request.
---
--- Backend: GraphQL. The full query (approvals, discussion counts,
--- `mergeabilityChecks`) falls back to a smaller query only when GitLab
--- reports a schema error (an older version without those fields). Auth,
--- network and other errors are returned as they are. Nothing is remembered
--- between calls.
local checks_model = require("gg.models.merge_checks")
local common = require("gg.resources.common")
local graphql = require("gg.graphql.client")

local M = {}

--- Merge readiness of a merge request. Pagination: not applicable.
---@param args { host: string, project: string|integer, iid: integer }
---@return gg.Task resolves with gg.MergeChecks
function M.get(args)
  return common.run(args, { host = "host", project = "project", iid = "id" }, function()
    local path, perr = graphql.project_path(args.host, args.project):await()
    if not path then
      return nil, perr
    end
    local vars = { fullPath = path, iid = tostring(args.iid) }
    local what = ("merge request %s!%s"):format(path, tostring(args.iid))
    local fallback = false
    local data, err = graphql.query(args.host, "mr_checks_full", vars):await()
    if err and graphql.is_schema_error(err) then
      fallback = true
      data, err = graphql.query(args.host, "mr_checks_base", vars):await()
    end
    if err then
      return nil, err
    end
    local node, nerr = graphql.require(data, "project.mergeRequest", what)
    if not node then
      return nil, nerr
    end
    return checks_model.from_graphql(node, fallback)
  end)
end

return M
