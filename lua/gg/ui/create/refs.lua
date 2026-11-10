--- Branches and tags for the creation popups: the matches the ref picker
--- lists, and the picker opened below a field of the popup.
local gg = require("gg")
local ref_picker = require("gg.ui.create.ref_picker")

local M = {}

M.BRANCHES = 50 -- matches asked for per kind
M.TAGS = 30

--- A branch as a picker item.
---@param b gg.Branch
---@return gg.ui.RefItem
function M.from_branch(b)
  return { name = b.name, kind = "branch", sha = b.commit_sha, title = b.commit_title, default = b.default }
end

--- A tag as a picker item.
---@param t gg.Tag
---@return gg.ui.RefItem
function M.from_tag(t)
  return { name = t.name, kind = "tag", sha = t.commit_sha, title = t.commit_title }
end

--- A `load(query, cb)` for the ref picker: the project's branches (and its
--- tags, with `tags`) whose name contains the query, searched on GitLab.
--- Branches come first; what fails to load is left out.
---@param ctx { host: string, project: string }
---@param tags? boolean
---@return fun(query: string, cb: fun(items: gg.ui.RefItem[]))
function M.loader(ctx, tags)
  return function(query, cb)
    local search = query ~= "" and query or nil
    local branches, tag_items
    local pending = tags and 2 or 1
    local function done()
      pending = pending - 1
      if pending == 0 then
        local out = branches or {}
        vim.list_extend(out, tag_items or {})
        cb(out)
      end
    end
    gg.branches.list({ host = ctx.host, project = ctx.project, search = search }, { per_page = M.BRANCHES }):on_done(function(page)
      branches = vim.tbl_map(M.from_branch, page and page.items or {})
      -- the default branch first
      table.sort(branches, function(a, b)
        if a.default ~= b.default then
          return a.default == true
        end
        return a.name < b.name
      end)
      done()
    end)
    if tags then
      gg.tags.list({ host = ctx.host, project = ctx.project, search = search }, { per_page = M.TAGS }):on_done(function(page)
        tag_items = vim.tbl_map(M.from_tag, page and page.items or {})
        done()
      end)
    end
  end
end

--- Open the ref picker below field `id` of popup `p`; `on_pick(item)` gets
--- the choice (default: it becomes the field's value).
---@param p gg.ui.CreatePopup
---@param id string
---@param opts { title: string, tags?: boolean, on_pick?: fun(item: gg.ui.RefItem) }
function M.pick(p, id, opts)
  local rect = p:field_rect(id)
  if not rect or p.data.ref_picker then
    return
  end
  p.data.ref_picker = true
  ref_picker.open({
    title = opts.title,
    row = rect.row + 3,
    col = rect.col,
    width = rect.width + 2,
    group = p.group,
    load = M.loader(p.ctx, opts.tags),
    on_pick = function(item)
      if p.closed then
        return
      end
      if opts.on_pick then
        opts.on_pick(item)
      else
        p:set_field(id, item.name)
      end
    end,
    on_close = function()
      p.data.ref_picker = nil
      if not p.closed then
        p:focus(require("gg.ui.create.popup").field_member(id))
      end
    end,
  })
end

return M
