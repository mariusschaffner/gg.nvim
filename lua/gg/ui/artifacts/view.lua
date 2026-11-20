--- The artifacts view of the picker: the project's CI job artifacts as a
--- tree (pipeline -> job › artifact -> folders -> files).
---
--- Loading:
---   * Jobs with artifacts come from `gg.jobs.list_project` (newest first,
---     PER_PAGE a page) until more than `limit` pipelines with visible
---     artifacts are known, or MAX_PAGES pages were read; the newest `limit`
---     pipelines are shown. `P` raises the limit by PIPELINES and reads on.
---   * `gg.projects.get` gives the default branch (ref colour, default
---     expansion) and the project's web URL.
---   * An archive's entries are listed the first time it is opened, from
---     `gg.artifacts.tree_all` (GitLab 18.8+, no download). When the server
---     cannot list it (not_found), the archive is downloaded to the cache
---     (asking first above `artifacts.confirm_size`) and its central
---     directory is read (`gg.ui.artifacts.zip`). Listings are cached by job
---     id while the view is open; a downloaded archive stays in the cache.
---   * Fold state is a set of node ids; it survives refresh, load-more and
---     filtering. While a filter is set, folds changed by the user are kept
---     apart, so clearing the filter restores the folds from before.
---   * The selection follows its node id, so lines inserted above or below
---     never move the cursor to another node.
local confirm = require("gg.ui.components.confirm")
local date = require("gg.ui.lib.date")
local filter = require("gg.ui.artifacts.filter")
local fs = require("gg.ui.artifacts.fs")
local gg = require("gg")
local highlights = require("gg.ui.highlights")
local hint = require("gg.ui.lib.hint")
local model = require("gg.ui.artifacts.model")
local paths = require("gg.ui.artifacts.paths")
local picker = require("gg.ui.components.picker")
local project = require("gg.ui.project")
local queue = require("gg.ui.components.queue")
local render = require("gg.ui.artifacts.render")
local size = require("gg.ui.lib.size")
local zip = require("gg.ui.artifacts.zip")

local M = {}

M.PIPELINES = 20 -- pipelines shown, and added by `P`
M.PER_PAGE = 100 -- jobs per request
M.MAX_PAGES = 10 -- requests per load at most
M.TREE_LIMIT = 20000 -- archive entries listed at most
M.OPEN_MAX = 5 * 1024 * 1024 -- `o` asks before opening a bigger file
M.FOLDER_CONFIRM = 20 -- `d` on a folder asks above this many files
M.DOWNLOADS = 2 -- downloads at a time
M.CACHE_ROOT = nil -- where archives are cached; nil = stdpath("cache")

---@class gg.ui.ArtifactsView
---@field name "artifacts"
---@field shell gg.ui.Picker
---@field host string|nil
---@field project string|nil
---@field status "idle"|"loading"|"ready"|"error"
---@field query string
---@field jobs gg.Job[] every loaded job, newest first
---@field job_ids table<integer, boolean>
---@field next_cursor string|nil
---@field limit integer pipelines to show
---@field open table<string, boolean> open node ids (without the filter)
---@field filter_folds table<string, boolean> folds changed while filtering
---@field entries table<integer, table[]> archive entries by job id
---@field listing table<integer, gg.ui.ArchiveListing>
---@field tree gg.ui.ArtifactTree|nil
---@field rendered gg.ui.Rendered|nil
---@field selected_id string|nil
local View = {}
View.__index = View

local function new(fields)
  return setmetatable(vim.tbl_extend("force", {
    name = "artifacts",
    filetype = "gg_ui_artifacts",
    placeholder = "Filter",
    status = "idle",
    query = "",
    jobs = {},
    job_ids = {},
    limit = M.PIPELINES,
    open = {},
    filter_folds = {},
    entries = {},
    listing = {},
    ctx = {},
    gen = 0,
    tasks = {},
    touched = false,
    closed = false,
    refreshing = false,
    loading_more = false,
    utc_offset = date.utc_offset(),
    downloads = queue.new({ concurrency = M.DOWNLOADS }),
    listings = queue.new({ concurrency = 2 }),
  }, fields), View)
end

--- Create the artifacts view inside an open picker (not activated).
---@param shell gg.ui.Picker
---@return gg.ui.ArtifactsView
function M.attach(shell)
  local self = new({ shell = shell, cfg = shell.cfg, keys = shell.keys, list = shell.list })
  shell:add(self)
  return self
end

---@private
function View:_active()
  return self.shell:is_active(self) and self.shell:valid()
end

---@private
function View:_acfg()
  return self.cfg.artifacts or {}
end

--- Called by the picker when this view becomes active: the first time it
--- starts loading, later it redraws.
function View:activate()
  highlights.setup()
  if self.status == "idle" then
    if self.shell.host then
      self.host, self.project = self.shell.host, self.shell.project
      self:load()
    else
      self:_resolve()
    end
    return
  end
  self:render()
end

---@private
function View:_resolve()
  self.status = "loading"
  self:render()
  local t = project.resolve(self.shell.target_opts or {})
  self.tasks.resolve = t
  t:on_done(function(target, err)
    if self.closed or self.tasks.resolve ~= t then
      return
    end
    self.tasks.resolve = nil
    if err then
      self.status, self.err_msg = "error", err.message or tostring(err)
      self:render()
      return
    end
    self.shell.host, self.shell.project = target.host, target.project
    self.host, self.project = target.host, target.project
    self:load()
  end)
end

---@private
function View:_cancel_tasks()
  for k, t in pairs(self.tasks) do
    t:cancel()
    self.tasks[k] = nil
  end
  self.loading_more = false
end

---@private
function View:_build(jobs, max_roots)
  return model.build(jobs or self.jobs, {
    now = os.time(),
    show_expired = self:_acfg().show_expired,
    entries = self.entries,
    listing = self.listing,
    max_roots = max_roots,
  })
end

-- Read job pages until more than `limit` pipelines are known (or the end, or
-- MAX_PAGES). Resolves with { jobs, next_cursor }.
---@private
function View:_fetch(jobs, seen, cursor, limit)
  local args = { host = self.host, project = self.project, with_artifacts = true }
  return gg.task.run(function()
    for _ = 1, M.MAX_PAGES do
      local page, err = gg.jobs.list_project(args, { per_page = M.PER_PAGE, cursor = cursor }):await()
      if not page then
        return nil, err
      end
      for _, j in ipairs(page.items) do
        if j.id and not seen[j.id] then
          seen[j.id] = true
          table.insert(jobs, j)
        end
      end
      cursor = page.next_cursor
      if not cursor or self:_build(jobs).total > limit then
        break
      end
    end
    return { jobs = jobs, next_cursor = cursor }
  end)
end

--- (Re)load the jobs. On a reload the rows stay until the new ones arrived;
--- folds, listings and the limit are kept, failed listings are retried.
function View:load()
  if self.closed then
    return
  end
  if not self.host then
    return self:_resolve()
  end
  self:_cancel_tasks()
  self.gen = self.gen + 1
  local gen = self.gen
  self.refreshing = self.status == "ready"
  if not self.refreshing then
    self.status, self.err_msg = "loading", nil
  end
  for job_id, l in pairs(self.listing) do
    if l.status == "error" then
      self.listing[job_id] = nil
    end
  end
  self:render()
  local t = self:_fetch({}, {}, nil, self.limit)
  self.tasks.page = t
  t:on_done(function(res, err)
    if self.closed or gen ~= self.gen then
      return
    end
    self.tasks.page = nil
    self.refreshing = false
    if err then
      if self.status == "ready" then
        vim.notify("gg.ui: refreshing artifacts failed: " .. (err.message or tostring(err)), vim.log.levels.WARN)
      else
        self.status, self.err_msg = "error", err.message or tostring(err)
      end
      self:render()
      return
    end
    local first = self.status ~= "ready"
    self.jobs, self.next_cursor = res.jobs, res.next_cursor
    self.job_ids = {}
    for _, j in ipairs(self.jobs) do
      self.job_ids[j.id] = true
    end
    self.status = "ready"
    if first then
      self.open = model.default_open(self:_build(nil, self.limit), self.ctx.default_branch)
      self.defaults_pending = self.ctx.default_branch == nil
    end
    self:render()
    self:_relist_open()
  end)
  self:_load_project(gen)
end

-- the default branch and the project's web URL
---@private
function View:_load_project(gen)
  if self.ctx.default_branch then
    return
  end
  local t = gg.projects.get({ host = self.host, project = self.project })
  self.tasks.project = t
  t:on_done(function(p, err)
    if self.closed or gen ~= self.gen then
      return
    end
    self.tasks.project = nil
    if err or not p then
      return
    end
    self.ctx.default_branch = p.default_branch
    self.ctx.web_url = p.web_url
    -- the jobs came first: open the default branch's pipeline now
    if self.defaults_pending and self.status == "ready" then
      self.defaults_pending = nil
      for id in pairs(model.default_open(self:_build(nil, self.limit), p.default_branch)) do
        self.open[id] = true
      end
    end
    self:render()
  end)
end

--- Show PIPELINES more pipelines, reading more jobs when needed.
function View:next_page()
  if self.closed or self.status ~= "ready" or self.loading_more then
    return
  end
  local total = self:_build().total
  if total <= self.limit and not self.next_cursor then
    return
  end
  self.limit = self.limit + M.PIPELINES
  if total > self.limit or not self.next_cursor then
    return self:render()
  end
  self.loading_more = true
  self:_chrome()
  local gen = self.gen
  local t = self:_fetch(self.jobs, self.job_ids, self.next_cursor, self.limit)
  self.tasks.more = t
  t:on_done(function(res, err)
    if self.closed or gen ~= self.gen then
      return
    end
    self.tasks.more = nil
    self.loading_more = false
    if err then
      vim.notify("gg.ui: loading more artifacts failed: " .. (err.message or tostring(err)), vim.log.levels.WARN)
      self:_chrome()
      return
    end
    self.jobs, self.next_cursor = res.jobs, res.next_cursor
    self:render()
  end)
end

-- Rendering -------------------------------------------------------------------

-- the folds in effect: the user's, the filter's auto-opens, and the folds
-- changed while filtering
---@private
function View:_effective_open(fres)
  local o = {}
  for id in pairs(self.open) do
    o[id] = true
  end
  if fres then
    for id in pairs(fres.auto_open) do
      o[id] = true
    end
    for id, v in pairs(self.filter_folds) do
      o[id] = v or nil
    end
  end
  return o
end

---@private
function View:_icon_of()
  if not self:_acfg().icons then
    return nil
  end
  if self._icons == nil then
    local ok, mini = pcall(require, "mini.icons")
    if ok and type(mini) == "table" and mini.get then
      self._icons = function(name)
        local ok2, icon, hl = pcall(mini.get, "file", name)
        return ok2 and icon or nil, hl
      end
    else
      local ok3, devicons = pcall(require, "nvim-web-devicons")
      if ok3 and type(devicons) == "table" and devicons.get_icon then
        self._icons = function(name)
          return devicons.get_icon(name, name:match("%.([^.]+)$"), { default = true })
        end
      else
        self._icons = false
      end
    end
  end
  return self._icons or nil
end

---@private
function View:_output()
  local tree, fres
  if self.status == "ready" then
    tree = self:_build(nil, self.limit)
    fres = filter.apply(tree, filter.parse(self.query), os.time())
  end
  self.tree, self.fres = tree, fres
  self.eff_open = self:_effective_open(fres)
  return render.render({
    width = self.shell:width(),
    status = self.status == "idle" and "loading" or self.status,
    tree = tree,
    open = self.eff_open,
    visible = fres and fres.visible or nil,
    default_branch = self.ctx.default_branch,
    now = os.time(),
    utc_offset = self.utc_offset,
    error = self.err_msg,
    retry_key = picker.first_key(self.keys.refresh) or false,
    icon_of = self:_icon_of(),
  })
end

--- Redraw the table from the current state; the selection follows its node.
function View:render()
  if self.closed or not self:_active() then
    return
  end
  if not self.touched then
    self.selected_id, self.sel_row = nil, nil
  end
  local r = self:_output()
  self.rendered = r
  self.list:set(r)
  local target
  if self.selected_id then
    for _, lnum in ipairs(r.selectable) do
      local node = r.rows[lnum].node
      if node and node.id == self.selected_id then
        target = lnum
        break
      end
    end
  end
  self._rendering = true
  self.list:select(target or self.sel_row)
  self._rendering = false
  self.shell.prompt:set_counter(nil) -- no match counter
  self:_chrome()
end

---@private
function View:_title()
  if self.refreshing then
    return " Table · refreshing… "
  end
  if self.loading_more then
    return (" Table · loading… %d "):format(self.limit)
  end
  local tree = self.tree
  if tree and (tree.total > #tree.roots or self.next_cursor) then
    local key = picker.first_key(self.keys.next_page)
    if key then
      return (" Table · %d pipelines · [%s] more "):format(#tree.roots, key)
    end
  end
  return " Table "
end

---@private
function View:_footer()
  local k = picker.first_key
  local hints = {}
  for _, h in ipairs({ { self.keys.download, "Download" }, { self.keys.open_file, "Open in buffer" }, { self.keys.yank_path, "Copy path" } }) do
    if k(h[1]) then
      table.insert(hints, { key = k(h[1]), desc = h[2] })
    end
  end
  return #hints > 0 and hint.chunks(hints) or " "
end

---@private
function View:_chrome()
  if self.closed or not self:_active() then
    return
  end
  self.shell:chrome(self:_title(), self:_footer())
end

-- Interaction -----------------------------------------------------------------

--- The cursor moved to `lnum` (called by the picker).
---@param lnum integer|nil
function View:on_select(lnum)
  local r = self.rendered
  local row = r and lnum and r.rows[lnum]
  if row and row.node and row.kind ~= "status" then
    self.selected_id = row.node.id
    self.sel_row = lnum
    if not self._rendering then
      self.touched = true
    end
  end
  self.shell:overlay(row and row.node and row.kind ~= "status" and lnum or nil)
end

--- Set the filter query and redraw. Folds changed while filtering are
--- dropped when the query changes.
---@param s string
function View:set_query(s)
  if self.closed or s == self.query then
    return
  end
  self.query = s
  self.filter_folds = {}
  self:render()
end

--- This view has no state tabs.
function View:switch_tab(_) end

---@private
function View:_current()
  local lnum = self.list:current()
  local row = lnum and self.rendered and self.rendered.rows[lnum]
  return row and row.kind ~= "status" and row.node or nil
end

---@private
function View:_is_open(node)
  return self.eff_open and self.eff_open[node.id] == true
end

---@private
function View:_set_open(node, open)
  if self.fres then
    self.filter_folds[node.id] = open
  else
    self.open[node.id] = open or nil
  end
  if open and node.kind == "artifact" and node.archive and model.listing(self.tree, node) == "unlisted" then
    self:_list_archive(node)
  end
end

--- Open or close the node under the cursor; on a file, open it.
function View:toggle()
  local node = self:_current()
  if not node then
    return
  end
  if not model.expandable(node) then
    return self:open_file()
  end
  self:_set_open(node, not self:_is_open(node))
  self:render()
end

--- `zo`: open the node under the cursor.
function View:fold_open()
  local node = self:_current()
  if node and model.expandable(node) and not self:_is_open(node) then
    self:_set_open(node, true)
    self:render()
  end
end

--- `zc` / `za` on a leaf: close the node, or the one containing it.
function View:fold_close()
  local node = self:_current()
  if not node then
    return
  end
  if model.expandable(node) and self:_is_open(node) then
    self:_set_open(node, false)
    return self:render()
  end
  self:close_parent()
end

--- `za`: toggle the node; on a leaf, close the one containing it.
function View:fold_toggle()
  local node = self:_current()
  if node and model.expandable(node) then
    self:_set_open(node, not self:_is_open(node))
    return self:render()
  end
  self:close_parent()
end

--- `h`: close the parent and move to it (an open pipeline closes itself).
function View:close_parent()
  local node = self:_current()
  if not node then
    return
  end
  local parent = model.parent(self.tree, node.id)
  if not parent then
    if self:_is_open(node) then
      self:_set_open(node, false)
      self:render()
    end
    return
  end
  self:_set_open(parent, false)
  self.selected_id, self.touched = parent.id, true
  self:render()
end

--- `zM`: close everything.
function View:close_all()
  if not self.tree then
    return
  end
  if self.fres then
    for id in pairs(self.eff_open or {}) do
      self.filter_folds[id] = false
    end
  else
    self.open = {}
  end
  self:render()
end

--- `zR`: open everything, but no archive that is not listed yet.
function View:open_all()
  if not self.tree then
    return
  end
  local all = {}
  model.open_all(self.tree, all)
  for id in pairs(all) do
    if self.fres then
      self.filter_folds[id] = true
    else
      self.open[id] = true
    end
  end
  self:render()
end

-- Archive listings --------------------------------------------------------------

---@private
function View:_listed(job_id, entries, err)
  if self.closed then
    return
  end
  if err then
    self.listing[job_id] = { status = "error", error = err }
  else
    self.entries[job_id] = entries
    self.listing[job_id] = { status = "listed" }
  end
  self:render()
end

-- archives that are open but not listed (after a refresh dropped an error)
---@private
function View:_relist_open()
  local tree = self.tree
  if not tree then
    return
  end
  for id in pairs(self.eff_open or {}) do
    local node = tree.by_id[id]
    if node and node.kind == "artifact" and node.archive and not node.expired and model.listing(tree, node) == "unlisted" then
      self:_list_archive(node)
    end
  end
end

--- List an archive's entries: GitLab's tree first, else the zip itself.
---@private
function View:_list_archive(node)
  local job_id = node.job.id
  self.listing[job_id] = { status = "loading" }
  local args = { host = self.host, project = self.project, job_id = job_id, recursive = true }
  self.listings:push("tree:" .. job_id, function()
    return gg.artifacts.tree_all(args, { limit = M.TREE_LIMIT, per_page = 100 })
  end, function(res, err)
    if self.closed then
      return
    end
    if not err then
      if res.truncated then
        vim.notify(("gg.ui: %s lists more than %d files; showing the first %d"):format(node.name, M.TREE_LIMIT, M.TREE_LIMIT), vim.log.levels.WARN)
      end
      return self:_listed(job_id, res.items)
    end
    if err.kind ~= "not_found" then
      return self:_listed(job_id, nil, err.message or tostring(err))
    end
    self:_list_from_zip(node)
  end)
end

---@private
function View:_cache_path(job_id)
  local key = vim.fn.sha256(self.host .. "/" .. tostring(self.project)):sub(1, 16)
  return ("%s/gg/artifacts/%s/%d.zip"):format(M.CACHE_ROOT or vim.fn.stdpath("cache"), key, job_id)
end

-- The server cannot list this archive: download it (asking first when it
-- is big) and read its central directory.
---@private
function View:_list_from_zip(node)
  local job_id = node.job.id
  local out = self:_cache_path(job_id)
  fs.size(out, function(have)
    if self.closed then
      return
    end
    if have then
      return self:_read_zip(job_id, out, have)
    end
    local limit = self:_acfg().confirm_size or 0
    local function fetch()
      fs.mkdir_p(vim.fs.dirname(out), function(_, merr)
        if merr then
          return self:_listed(job_id, nil, merr)
        end
        self.listings:push("zip:" .. job_id, function()
          return gg.artifacts.download({ host = self.host, project = self.project, job_id = job_id, output = out })
        end, function(d, err)
          if err then
            return self:_listed(job_id, nil, err.message or tostring(err))
          end
          self:_read_zip(job_id, out, d.bytes)
        end)
      end)
    end
    if node.size and limit > 0 and node.size > limit then
      confirm.ask(("Download %s to browse?"):format(size.human(node.size)), fetch, function()
        -- not now: back to closed and unlisted
        self.listing[job_id] = nil
        self.open[node.id], self.filter_folds[node.id] = nil, nil
        self:render()
      end)
    else
      fetch()
    end
  end)
end

---@private
function View:_read_zip(job_id, path, file_size)
  local tail_len = math.min(file_size, zip.TAIL)
  local tail_at = file_size - tail_len
  local function read_cd(dir)
    fs.read(path, dir.cd_offset, dir.cd_size, function(cd, rerr)
      if not cd then
        return self:_listed(job_id, nil, rerr)
      end
      local entries, perr = zip.entries(cd)
      self:_listed(job_id, entries, perr)
    end)
  end
  fs.read(path, tail_at, tail_len, function(tail, err)
    if not tail then
      return self:_listed(job_id, nil, err)
    end
    local dir, derr = zip.eocd(tail, tail_at)
    if not dir then
      return self:_listed(job_id, nil, derr)
    end
    if dir.need then
      return fs.read(path, dir.need.offset, dir.need.length, function(rec, rerr)
        local d64, e64 = rec and zip.eocd64(rec) or nil, rerr
        if not d64 then
          return self:_listed(job_id, nil, e64 or "bad Zip64 record")
        end
        read_cd(d64)
      end)
    end
    read_cd(dir)
  end)
end

-- Actions -----------------------------------------------------------------------

---@private
function View:_base(node)
  local dir = vim.fs.normalize(vim.fn.expand(self:_acfg().download_dir or "~/Downloads"))
  return paths.base(dir, self.project, node.pipeline.id)
end

-- the request that downloads one file or artifact to `out`
---@private
function View:_download_task(node, out)
  local args = { host = self.host, project = self.project, job_id = node.job.id, output = out }
  if node.kind == "file" then
    args.artifact_path = node.path
    return gg.artifacts.download_file(args)
  end
  if not node.archive then
    args.file_type = node.artifact.file_type
  end
  return gg.artifacts.download(args)
end

-- download nodes (files or whole artifacts); one notice when all are done
---@private
function View:_download(nodes)
  local total, ok, failed, last = #nodes, 0, {}, nil
  if total == 0 then
    return
  end
  local function finished()
    if ok + #failed < total then
      return
    end
    if #failed > 0 then
      vim.notify(("gg.ui: %d of %d downloads failed: %s"):format(#failed, total, failed[1]), vim.log.levels.ERROR)
    end
    if ok == 1 and total == 1 then
      vim.notify(("Downloaded %s → %s/"):format(vim.fs.basename(last), vim.fn.fnamemodify(vim.fs.dirname(last), ":~")))
    elseif ok > 0 then
      vim.notify(("Downloaded %d files → %s/"):format(ok, vim.fn.fnamemodify(self:_base(nodes[1]), ":~")))
    end
  end
  for _, node in ipairs(nodes) do
    local out = paths.target(self:_base(node), node)
    fs.mkdir_p(vim.fs.dirname(out), function(_, merr)
      if merr then
        table.insert(failed, merr)
        return finished()
      end
      self.downloads:push(out, function()
        return self:_download_task(node, out)
      end, function(_, err)
        if err then
          table.insert(failed, ("%s: %s"):format(node.name, err.message or tostring(err)))
        else
          ok, last = ok + 1, out
        end
        finished()
      end)
    end)
  end
end

--- `d`: download the file, artifact, folder or pipeline under the cursor.
function View:download()
  local node = self:_current()
  if not node then
    return
  end
  if node.kind == "file" or node.kind == "artifact" then
    return self:_download({ node })
  end
  if node.kind == "dir" then
    local files = model.files_below(node)
    if #files > M.FOLDER_CONFIRM then
      return confirm.ask(("Download %d files of %s/?"):format(#files, node.name), function()
        self:_download(files)
      end)
    end
    return self:_download(files)
  end
  local arts = node.children
  confirm.ask(("Download %d artifact%s of %s?"):format(#arts, #arts == 1 and "" or "s", node.name), function()
    self:_download(arts)
  end)
end

-- show a fetched text file in a read-only buffer
---@private
function View:_show(node, lines)
  local name = paths.buffer_name(node)
  local where = self:_acfg().open or "tab"
  -- the picker closes when the focus leaves it (as for every view), and a
  -- float cannot be split: close it first, then open from the window below
  self.shell:close()
  vim.cmd(where == "tab" and "tabnew" or where)
  local existing = vim.fn.bufnr(name)
  local buf = existing ~= -1 and existing or vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(0, buf)
  if existing == -1 then
    vim.api.nvim_buf_set_name(buf, name)
  end
  local bo = vim.bo[buf]
  bo.modifiable = true
  bo.readonly = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  bo.buftype, bo.bufhidden, bo.swapfile = "nofile", "hide", false
  bo.modifiable, bo.readonly, bo.modified = false, true, false
  local ft = vim.filetype.match({ filename = node.kind == "file" and node.path or node.name, buf = buf })
  if ft then
    bo.filetype = ft
  end
end

---@private
function View:_offer_download(node, why)
  confirm.ask(("%s %s. Download it instead?"):format(node.name, why), function()
    self:_download({ node })
  end)
end

---@private
function View:_fetch_and_show(node)
  local tmp = vim.fn.tempname()
  local t = self:_download_task(node, tmp)
  self.tasks["open:" .. node.id] = t
  t:on_done(function(d, err)
    if self.tasks["open:" .. node.id] == t then
      self.tasks["open:" .. node.id] = nil
    end
    if self.closed then
      return os.remove(tmp)
    end
    if err then
      vim.notify(("gg.ui: opening %s failed: %s"):format(node.name, err.message or tostring(err)), vim.log.levels.ERROR)
      return
    end
    fs.read(tmp, 0, d.bytes, function(data, rerr)
      os.remove(tmp)
      if not data then
        vim.notify(("gg.ui: opening %s failed: %s"):format(node.name, rerr or "?"), vim.log.levels.ERROR)
        return
      end
      local binary, gzip = paths.sniff(data:sub(1, 8192))
      if binary then
        return self:_offer_download(node, gzip and "is compressed" or "is a binary file")
      end
      local lines = vim.split(data:gsub("\r\n", "\n"), "\n", { plain = true })
      if lines[#lines] == "" then
        table.remove(lines)
      end
      self:_show(node, lines)
    end)
  end)
end

--- `o`: open the file under the cursor in a read-only buffer.
function View:open_file()
  local node = self:_current()
  if not node or not (node.kind == "file" or (node.kind == "artifact" and not node.archive)) then
    return
  end
  if node.size and node.size > M.OPEN_MAX then
    return confirm.ask(("%s is %s. Open it anyway?"):format(node.name, size.human(node.size)), function()
      self:_fetch_and_show(node)
    end, function()
      self:_offer_download(node, "is big")
    end)
  end
  self:_fetch_and_show(node)
end

local function yank(s)
  vim.fn.setreg('"', s)
  pcall(vim.fn.setreg, "+", s)
  vim.notify("Copied " .. s)
end

--- `y`: copy the path inside the artifact.
function View:yank_path()
  local node = self:_current()
  local s = node and paths.inner_path(node)
  if s then
    yank(s)
  end
end

--- `Y`: copy the GitLab web URL.
function View:yank_url()
  local node = self:_current()
  local s = node and paths.web_url(node)
  if s then
    yank(s)
  end
end

--- The view's own table keymaps (the shell maps the shared ones).
---@return { [1]: gg.ui.Keymap, [2]: fun(), [3]: string }[]
function View:keymaps()
  local k = self.keys
  local function call(method)
    return function()
      self[method](self)
    end
  end
  return {
    { k.toggle_node, call("toggle"), "Open/close; open a file" },
    { k.close_parent, call("close_parent"), "Close the parent" },
    { k.toggle_fold, call("fold_toggle"), "Toggle the node" },
    { k.fold_open, call("fold_open"), "Open the node" },
    { k.fold_close, call("fold_close"), "Close the node" },
    { k.fold_close_all, call("close_all"), "Close every node" },
    { k.fold_open_all, call("open_all"), "Open every listed node" },
    { k.download, call("download"), "Download" },
    { k.open_file, call("open_file"), "Open in a buffer" },
    { k.yank_path, call("yank_path"), "Copy the path" },
    { k.yank_url, call("yank_url"), "Copy the web URL" },
    { k.next_page, call("next_page"), "Load more pipelines" },
  }
end

--- The picker closed: cancel loading and listing (called by the picker).
--- Downloads the user started run on and still report when done.
function View:teardown()
  if self.closed then
    return
  end
  self.closed = true
  self:_cancel_tasks()
  self.listings:cancel_all()
end

--- Open a picker on the artifacts view (same options as the other views).
---@param opts? { arg?: string, host?: string, project?: string, cwd?: string, config?: gg.ui.Config }
---@return gg.ui.ArtifactsView
function M.open(opts)
  opts = opts or {}
  local cfg = opts.config or require("gg.ui.config").get()
  highlights.setup()
  local direct = opts.host and opts.project
  local shell = picker.new({
    cfg = cfg,
    filetype = "gg_ui_artifacts",
    host = direct and opts.host or nil,
    project = direct and opts.project or nil,
    target_opts = not direct and { arg = opts.arg or opts.project, cwd = opts.cwd } or nil,
  })
  local self = M.attach(shell)
  shell:activate(self)
  return self
end


return M
