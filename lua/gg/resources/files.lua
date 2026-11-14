--- Repository files: raw content at a ref, always streamed to a file or a
--- callback.
---
--- Backend: REST (docs.gitlab.com/api/repository_files):
---   * GET /projects/:id/repository/files/:file_path/raw?ref=
---
--- The file path is one URL-encoded segment (`lib/a.rb` -> `lib%2Fa.rb`).
--- A partial file is removed on failure or cancel.
local common = require("gg.resources.common")
local download = require("gg.models.download")
local rest = require("gg.rest.client")
local task = require("gg.core.task")

local M = {}

--- Download a file's raw content at a ref (branch, tag or commit SHA).
---@param args { host: string, project: string|integer, path: string, ref: string, output?: string, on_chunk?: fun(data: string), lfs?: boolean }
---@return gg.Task resolves with gg.Download
function M.raw(args)
  local spec = { host = "host", project = "project", path = "string", ref = "string", output = "string?", on_chunk = "callback?", lfs = "boolean?" }
  local err = common.check(args, spec)
  if err then
    return task.failed(err)
  end
  if (args.output == nil) == (args.on_chunk == nil) then
    return task.failed(common.invalid("output", "or args.on_chunk is required (exactly one): downloads are never buffered whole"))
  end
  return task.run(function()
    local path = ("/projects/%s/repository/files/%s/raw"):format(rest.project(args.project), rest.seg(args.path))
    local res, rerr = rest.request(args.host, "GET", path, {
      query = { ref = args.ref, lfs = args.lfs },
      output = args.output,
      on_chunk = args.on_chunk,
    }):await()
    if rerr then
      return nil, rerr
    end
    return download.new(args.output, res.bytes)
  end)
end

return M
