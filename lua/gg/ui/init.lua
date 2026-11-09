--- gg.ui: the optional UI layer on top of the gg API.
---
--- It talks to GitLab only through `require("gg")` (the facade). See
--- `:help gg-ui`.
local config = require("gg.ui.config")
local highlights = require("gg.ui.highlights")

local M = {}

--- Configure the UI (keymaps, callbacks, limits). Separate from
--- `require("gg").setup()`. Returns `true`, or `false, err` (the previous
--- options stay).
---@param opts? table see gg.ui.Config
---@return boolean ok
---@return gg.Error|nil err
function M.setup(opts)
  local ok, err = config.setup(opts)
  if ok then
    highlights.setup()
  end
  return ok, err
end

--- Open the picker (issues and merge requests; `<Tab>` switches).
--- `opts.project`: `[host/]group/project` or a remote URL; without it, the
--- `origin` remote of the current directory. `opts.host` with
--- `opts.project` opens that target directly. `opts.view` picks the view
--- shown first: "issues" (default) or "merge_requests".
---@param opts? { project?: string, host?: string, cwd?: string, view?: "issues"|"merge_requests" }
---@return gg.ui.IssuesView|gg.ui.MrView
function M.open(opts)
  opts = opts or {}
  local name = opts.view or "issues"
  local view = require(name == "merge_requests" and "gg.ui.merge_requests.view" or "gg.ui.issues.view")
  if opts.host and opts.project then
    return view.open({ host = opts.host, project = opts.project })
  end
  return view.open({ arg = opts.project, cwd = opts.cwd })
end

return M
