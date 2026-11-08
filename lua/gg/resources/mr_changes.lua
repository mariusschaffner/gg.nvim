--- Merge request changes: commits, diffs, diff stats and diff versions.
---
--- Backends:
---   * commits: GraphQL `mergeRequest.commits`.
---   * diffs: REST `/merge_requests/:iid/diffs` (paginated), not the
---     deprecated `/changes` endpoint.
---   * diffstat: derived from the diffs pages (status from the file flags,
---     counts from the diff text), so it needs a limit like any collect-all.
---   * versions: REST `/merge_requests/:iid/versions` (diff refs for
---     positioned comments).
local common = require("gg.resources.common")
local diff_model = require("gg.models.diff")
local errors = require("gg.core.errors")
local graphql = require("gg.graphql.client")
local rest = require("gg.rest.client")
local task = require("gg.core.task")

local M = {}

M.COMMITS_PER_PAGE = 100
M.DIFFS_PER_PAGE = 100
M.VERSIONS_PER_PAGE = 100

local MR_SPEC = { host = "host", project = "project", iid = "id" }

local function mr_path(args, suffix)
  return ("/projects/%s/merge_requests/%d/%s"):format(rest.project(args.project), common.int(args.iid), suffix)
end

local function commits_fetch(args, o)
  local err = common.check(args, MR_SPEC)
  if err then
    return task.failed(err)
  end
  local origin = common.origin(args.host)
  return task.run(function()
    local path, perr = graphql.project_path(args.host, args.project):await()
    if not path then
      return nil, perr
    end
    local page, gerr = graphql.page(args.host, "mr_commits", { fullPath = path, iid = tostring(args.iid) }, "project.mergeRequest.commits", {
      cursor = o.cursor,
      per_page = o.per_page,
      default_per_page = M.COMMITS_PER_PAGE,
      what = ("merge request %s!%s"):format(path, tostring(args.iid)),
    }):await()
    if not page then
      return nil, gerr
    end
    return {
      items = vim.tbl_map(function(n)
        return diff_model.commit_from_graphql(n, { origin = origin })
      end, page.items),
      next_cursor = page.next_cursor,
    }
  end)
end

local commits, commits_all = common.lists(commits_fetch)

--- One page of a merge request's commits. Resolves with `gg.Page<gg.Commit>`.
---@param args { host: string, project: string|integer, iid: integer }
---@param opts? { per_page?: integer, cursor?: string } per_page default 100
---@return gg.Task
function M.commits(args, opts)
  return commits(args, opts)
end

--- All commits up to `opts.limit`. Resolves with `{ items: gg.Commit[], truncated: boolean }`.
---@param args { host: string, project: string|integer, iid: integer }
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.Commit[]) }
---@return gg.Task
function M.commits_all(args, opts)
  return commits_all(args, opts)
end

local DIFF_SPEC = { host = "host", project = "project", iid = "id", unidiff = "boolean?" }

local function diffs_fetch(args, o)
  local err = common.check(args, DIFF_SPEC)
  if err then
    return task.failed(err)
  end
  return task.run(function()
    local page, rerr = rest.page(args.host, mr_path(args, "diffs"), {
      query = { unidiff = args.unidiff },
      per_page = o.per_page,
      default_per_page = M.DIFFS_PER_PAGE,
      cursor = o.cursor,
    }):await()
    if not page then
      return nil, rerr
    end
    return { items = vim.tbl_map(diff_model.file_from_rest, page.items), next_cursor = page.next_cursor }
  end)
end

local diffs, diffs_all = common.lists(diffs_fetch)

--- One page of a merge request's file diffs. Resolves with `gg.Page<gg.DiffFile>`.
---@param args { host: string, project: string|integer, iid: integer, unidiff?: boolean }
---@param opts? { per_page?: integer, cursor?: string } per_page default 100
---@return gg.Task
function M.diffs(args, opts)
  return diffs(args, opts)
end

--- All file diffs up to `opts.limit`. Resolves with `{ items: gg.DiffFile[], truncated: boolean }`.
---@param args { host: string, project: string|integer, iid: integer, unidiff?: boolean }
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.DiffFile[]) }
---@return gg.Task
function M.diffs_all(args, opts)
  return diffs_all(args, opts)
end

--- Per-file diff stats for up to `opts.limit` files. Resolves with
--- `{ items: gg.DiffStat[], truncated: boolean }`.
---@param args { host: string, project: string|integer, iid: integer }
---@param opts { limit: integer, per_page?: integer }
---@return gg.Task
function M.diffstat(args, opts)
  local err = common.check(args, MR_SPEC)
  if err then
    return task.failed(err)
  end
  return task.run(function()
    local res, derr = diffs_all(args, opts):await()
    if not res then
      return nil, derr
    end
    return { items = vim.tbl_map(diff_model.stat, res.items), truncated = res.truncated }
  end)
end

local function versions_fetch(args, o)
  local err = common.check(args, MR_SPEC)
  if err then
    return task.failed(err)
  end
  return task.run(function()
    local page, rerr = rest.page(args.host, mr_path(args, "versions"), {
      per_page = o.per_page,
      default_per_page = M.VERSIONS_PER_PAGE,
      cursor = o.cursor,
    }):await()
    if not page then
      return nil, rerr
    end
    return { items = vim.tbl_map(diff_model.version_from_rest, page.items), next_cursor = page.next_cursor }
  end)
end

local versions, versions_all = common.lists(versions_fetch)

--- One page of diff versions, newest first. Resolves with `gg.Page<gg.MergeRequestVersion>`.
---@param args { host: string, project: string|integer, iid: integer }
---@param opts? { per_page?: integer, cursor?: string }
---@return gg.Task
function M.versions(args, opts)
  return versions(args, opts)
end

--- All diff versions up to `opts.limit`.
---@param args { host: string, project: string|integer, iid: integer }
---@param opts { limit: integer, per_page?: integer, on_page?: fun(items: gg.MergeRequestVersion[]) }
---@return gg.Task resolves with { items: gg.MergeRequestVersion[], truncated: boolean }
function M.versions_all(args, opts)
  return versions_all(args, opts)
end

--- The newest diff version (its `diff_refs` position new comments).
---@param args { host: string, project: string|integer, iid: integer }
---@return gg.Task resolves with gg.MergeRequestVersion
function M.latest_version(args)
  return common.run(args, MR_SPEC, function()
    local page, err = versions(args, { per_page = 1 }):await()
    if not page then
      return nil, err
    end
    local v = page.items[1]
    if not v then
      return nil, errors.new("not_found", "the merge request has no diff versions yet", { details = { iid = args.iid } })
    end
    return v
  end)
end

return M
