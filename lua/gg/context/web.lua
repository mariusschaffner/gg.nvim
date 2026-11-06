--- Parse GitLab web URLs and short references (#12, !3, group/repo#12).
---
--- Pure: no config access, no gg requires outside context.
local remote = require("gg.context.remote")

local M = {}

---@alias gg.WebKind "project"|"issue"|"merge_request"|"pipeline"|"job"|"milestone"|"work_item"

---@class gg.WebTarget
---@field host string canonical host name
---@field base_url string
---@field project string full project path
---@field kind gg.WebKind
---@field iid integer|nil issues, merge requests, milestones, work items
---@field id integer|nil pipelines, jobs

---@class gg.Ref
---@field kind "issue"|"merge_request"
---@field project string|nil
---@field iid integer

-- path segment after /-/ -> kind, and whether the number is an iid or an id
local KINDS = {
  issues = { "issue", "iid" },
  merge_requests = { "merge_request", "iid" },
  pipelines = { "pipeline", "id" },
  jobs = { "job", "id" },
  milestones = { "milestone", "iid" },
  work_items = { "work_item", "iid" },
}

local function fail(message, details)
  return nil, { kind = "validation", message = message, details = details or {} }
end

local function target(kind_seg, number_seg, tail)
  local k = KINDS[kind_seg]
  if not k then
    return nil, "unsupported GitLab URL kind: " .. tostring(kind_seg)
  end
  if not number_seg or not number_seg:match("^%d+$") then
    return nil, "expected a number after /" .. kind_seg .. "/"
  end
  if tail ~= "" and tail:sub(1, 1) ~= "/" then
    return nil, "unexpected text after the number"
  end
  return { kind = k[1], field = k[2], value = tonumber(number_seg) }, nil
end

--- Parse a GitLab web URL (issue, merge request, pipeline, job, milestone,
--- work item, or the project itself).
---@param url string
---@param opts? gg.ContextOptions
---@return gg.WebTarget|nil
---@return gg.Error|nil err a plain table { kind = "validation", message, details }
function M.parse_web_url(url, opts)
  if type(url) ~= "string" then
    return fail("URL must be a string")
  end
  url = vim.trim(url)
  local scheme = url:match("^(%a[%w+%.%-]*)://")
  if not scheme or (scheme:lower() ~= "https" and scheme:lower() ~= "http") then
    return fail("not an http(s) URL")
  end
  url = url:gsub("[?#].*$", "")

  -- the project path ends at "/-/" (modern URLs)
  local before, after = url:match("^(.-)/%-/(.*)$")
  local parsed, err
  if before then
    parsed, err = remote.parse(before, opts)
    if not parsed then
      return nil, err
    end
    local kind_seg, number_seg, tail = after:match("^([%w_]+)/?([^/]*)(.*)$")
    local t, terr = target(kind_seg, number_seg, tail or "")
    if not t then
      return fail(terr, { project = parsed.project })
    end
    return {
      host = parsed.host,
      base_url = parsed.base_url,
      project = parsed.project,
      kind = t.kind,
      [t.field] = t.value,
    }, nil
  end

  parsed, err = remote.parse(url, opts)
  if not parsed then
    return nil, err
  end
  -- legacy URLs without "/-/": group/repo/issues/12
  local proj, kind_seg, number_seg = parsed.project:match("^(.+/[^/]+)/([%w_]+)/(%d+)$")
  if proj and KINDS[kind_seg] then
    local k = KINDS[kind_seg]
    return {
      host = parsed.host,
      base_url = parsed.base_url,
      project = proj,
      kind = k[1],
      [k[2]] = tonumber(number_seg),
    }, nil
  end
  return { host = parsed.host, base_url = parsed.base_url, project = parsed.project, kind = "project" }, nil
end

--- Parse a short reference: "#12" / "!3" (needs `default_project`), or
--- "group/repo#12" / "group/sub/repo!3".
---@param ref string
---@param default_project? string
---@return gg.Ref|nil
---@return gg.Error|nil err a plain table { kind = "validation", message, details }
function M.parse_ref(ref, default_project)
  if type(ref) ~= "string" then
    return fail("reference must be a string")
  end
  ref = vim.trim(ref)
  local project, sigil, num = ref:match("^([^%s#!]*)([#!])(%d+)$")
  if not sigil then
    return fail("not a reference like #12, !3 or group/repo#12", { ref = ref })
  end
  if project == "" then
    project = default_project
    if type(project) ~= "string" or project == "" then
      return fail("a reference without a project needs a default project", { ref = ref })
    end
  elseif not project:match("^[^/]+/.+[^/]$") or project:find("//", 1, true) then
    return fail("the project in a reference must be a full path like group/repo", { ref = ref })
  end
  return { kind = sigil == "#" and "issue" or "merge_request", project = project, iid = tonumber(num) }, nil
end

return M
