--- Container registry (read-only): repositories and tags.
---
--- Backends: repositories via GraphQL `project.containerRepositories`; tags
--- via REST `/registry/repositories/:id/tags` with keyset pagination (a
--- documented keyset endpoint, `order_by=name`); one tag via REST.
local common = require("gg.resources.common")
local graphql = require("gg.graphql.client")
local registry_model = require("gg.models.registry")
local rest = require("gg.rest.client")
local task = require("gg.core.task")

local M = {}

M.DEFAULT_PER_PAGE = 50

local function repos_fetch(args, o)
  local err = common.check(args, { host = "host", project = "project", name = "string?" })
  if err then
    return task.failed(err)
  end
  return task.run(function()
    local path, perr = graphql.project_path(args.host, args.project):await()
    if not path then
      return nil, perr
    end
    local page, gerr = graphql.page(args.host, "container_repositories_list", { fullPath = path, name = args.name }, "project.containerRepositories", {
      cursor = o.cursor,
      per_page = o.per_page,
      default_per_page = M.DEFAULT_PER_PAGE,
      what = "project " .. path,
    }):await()
    if not page then
      return nil, gerr
    end
    return { items = vim.tbl_map(registry_model.repository_from_graphql, page.items), next_cursor = page.next_cursor }
  end)
end

local repositories, repositories_all = common.lists(repos_fetch)

--- One page of a project's container repositories. Resolves with `gg.Page<gg.ContainerRepository>`.
---@param args { host: string, project: string|integer, name?: string }
---@param opts? { per_page?: integer, cursor?: string }
---@return gg.Task
function M.repositories(args, opts)
  return repositories(args, opts)
end

--- All container repositories up to `opts.limit`.
---@param args { host: string, project: string|integer, name?: string }
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.ContainerRepository[]) }
---@return gg.Task resolves with { items: gg.ContainerRepository[], truncated: boolean }
function M.repositories_all(args, opts)
  return repositories_all(args, opts)
end

local TAG_SPEC = { host = "host", project = "project", repository_id = "id", sort = common.enum(true, "asc", "desc") }

local function tags_fetch(args, o)
  local err = common.check(args, TAG_SPEC)
  if err then
    return task.failed(err)
  end
  return task.run(function()
    local path = ("/projects/%s/registry/repositories/%d/tags"):format(rest.project(args.project), common.int(args.repository_id))
    local page, rerr = rest.page(args.host, path, {
      pagination = "keyset",
      query = { order_by = "name", sort = args.sort or "asc" },
      per_page = o.per_page,
      default_per_page = M.DEFAULT_PER_PAGE,
      cursor = o.cursor,
    }):await()
    if not page then
      return nil, rerr
    end
    return { items = vim.tbl_map(registry_model.tag_from_rest, page.items), next_cursor = page.next_cursor }
  end)
end

local tags, tags_all = common.lists(tags_fetch)

--- One page of a repository's tags, by name. Resolves with `gg.Page<gg.ContainerTag>`.
---@param args { host: string, project: string|integer, repository_id: integer, sort?: "asc"|"desc" }
---@param opts? { per_page?: integer, cursor?: string }
---@return gg.Task
function M.tags(args, opts)
  return tags(args, opts)
end

--- All tags up to `opts.limit`.
---@param args { host: string, project: string|integer, repository_id: integer, sort?: "asc"|"desc" }
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.ContainerTag[]) }
---@return gg.Task resolves with { items: gg.ContainerTag[], truncated: boolean }
function M.tags_all(args, opts)
  return tags_all(args, opts)
end

--- One tag with its digest and size.
---@param args { host: string, project: string|integer, repository_id: integer, name: string }
---@return gg.Task resolves with gg.ContainerTag
function M.tag(args)
  return common.run(args, { host = "host", project = "project", repository_id = "id", name = "string" }, function()
    local path = ("/projects/%s/registry/repositories/%d/tags/%s"):format(rest.project(args.project), common.int(args.repository_id), rest.seg(args.name))
    local res, err = rest.request(args.host, "GET", path):await()
    if err then
      return nil, err
    end
    return registry_model.tag_from_rest(res.data)
  end)
end

return M
