--- Users: the current user and project members.
---
--- Backends: GraphQL `currentUser` and `project.projectMembers`. Members are
--- listed through every relation REST `/members/all` covers (direct,
--- inherited, invited groups, shared into ancestors). One code path replaces
--- atlas's two `/user` copies and three member-list copies.
local common = require("gg.resources.common")
local errors = require("gg.core.errors")
local gid = require("gg.models.gid")
local graphql = require("gg.graphql.client")
local task = require("gg.core.task")
local user_model = require("gg.models.user")
local util = require("gg.models.util")

local M = {}

M.DEFAULT_PER_PAGE = 100

-- the same members REST GET /projects/:id/members/all returns
M.RELATIONS = { "DIRECT", "INHERITED", "INVITED_GROUPS", "SHARED_INTO_ANCESTORS" }

---@class gg.Member : gg.User
---@field access_level integer|nil 10 guest ... 50 owner
---@field member_id integer|nil

--- The user the host's token belongs to.
---@param args { host: string }
---@return gg.Task resolves with gg.User; an `auth` error when there is no signed-in user
function M.current(args)
  return common.run(args, { host = "host" }, function()
    local data, err = graphql.query(args.host, "user_current", {}):await()
    if err then
      return nil, err
    end
    local node = util.value(data.currentUser)
    if node == nil then
      return nil, errors.new("auth", ("no signed-in user on %s (is a token configured?)"):format(args.host), {
        details = { host = args.host },
      })
    end
    return user_model.from_graphql(node, { origin = common.origin(args.host) })
  end)
end

---@class gg.MemberListArgs
---@field host string
---@field project string|integer
---@field search? string filter by name or username

local SPEC = { host = "host", project = "project", search = "string?" }

local function fetch_page(args, o)
  local err = common.check(args, SPEC)
  if err then
    return task.failed(err)
  end
  local origin = common.origin(args.host)
  return task.run(function()
    local path, perr = graphql.project_path(args.host, args.project):await()
    if not path then
      return nil, perr
    end
    local page, gerr = graphql.page(args.host, "project_members_list", {
      fullPath = path,
      search = args.search,
      relations = M.RELATIONS,
    }, "project.projectMembers", {
      cursor = o.cursor,
      per_page = o.per_page,
      default_per_page = M.DEFAULT_PER_PAGE,
      what = "project " .. path,
    }):await()
    if not page then
      return nil, gerr
    end
    local items = {}
    for _, node in ipairs(page.items) do
      -- members whose user is not visible (e.g. pending invites) have no user
      local u = user_model.from_graphql(node.user, { origin = origin })
      if u then
        local level = util.value(node.accessLevel)
        u.access_level = level and tonumber(util.value(level.integerValue)) or nil
        u.member_id = gid.tail(util.value(node.id))
        table.insert(items, u)
      end
    end
    return { items = items, next_cursor = page.next_cursor }
  end)
end

local list, list_all = common.lists(fetch_page)

--- One page of project members (direct and inherited). Resolves with
--- `gg.Page<gg.Member>`. A page can hold fewer items than `per_page` when
--- some members have no visible user.
---@param args gg.MemberListArgs
---@param opts? { per_page?: integer, cursor?: string } per_page default 100
---@return gg.Task
function M.project_members(args, opts)
  return list(args, opts)
end

--- All project members up to `opts.limit`. Resolves with `{ items: gg.Member[], truncated: boolean }`.
---@param args gg.MemberListArgs
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.Member[]) }
---@return gg.Task
function M.project_members_all(args, opts)
  return list_all(args, opts)
end

return M
