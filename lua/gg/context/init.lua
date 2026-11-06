--- Context: turn remote URLs, web URLs and short references into explicit
--- hosts and project paths. Pure; never calls git.
local remote = require("gg.context.remote")
local web = require("gg.context.web")

local M = {}

--- Parse a git remote URL. See `gg.context.remote.parse`.
---@param url string
---@param opts? gg.ContextOptions
---@return gg.Remote|nil
---@return gg.Error|nil
function M.parse(url, opts)
  return remote.parse(url, opts)
end

--- Parse a GitLab web URL. See `gg.context.web.parse_web_url`.
---@param url string
---@param opts? gg.ContextOptions
---@return gg.WebTarget|nil
---@return gg.Error|nil
function M.parse_web_url(url, opts)
  return web.parse_web_url(url, opts)
end

--- Parse a short reference (#12, !3, group/repo#12).
---@param ref string
---@param default_project? string
---@return gg.Ref|nil
---@return gg.Error|nil
function M.parse_ref(ref, default_project)
  return web.parse_ref(ref, default_project)
end

return M
