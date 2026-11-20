--- The artifacts tree as data: pipelines -> artifacts -> folders -> files.
--- Pure.
---
--- `build` turns the loaded jobs (and the archive listings fetched so far)
--- into a tree. Fold state is a set of open node ids that the view keeps
--- while it is open; node ids are stable across rebuilds, so folds survive
--- refresh, load-more and filtering:
---
---   p:<pipeline id>             a pipeline (root)
---   a:<job id>:<file type>      an artifact (an archive or a report)
---   d:<job id>:<path/>          a folder inside an archive
---   f:<job id>:<path>           a file inside an archive
local expires = require("gg.ui.artifacts.expires")

local M = {}

--- Artifact types that are never shown.
M.HIDDEN_TYPES = { trace = true, metadata = true }

---@alias gg.ui.ArtifactNodeKind "pipeline"|"artifact"|"dir"|"file"

---@class gg.ui.ArtifactNode
---@field id string
---@field kind gg.ui.ArtifactNodeKind
---@field name string pipeline: "#<id>"; artifact: its file name; dir/file: the last path segment
---@field path string|nil dir/file: the path inside the archive ("reports/", "reports/a.md")
---@field size integer|nil bytes (pipelines and folders: the sum below them)
---@field files integer|nil folders: the number of files below
---@field children gg.ui.ArtifactNode[]
---@field parent string|nil parent id
---@field pipeline gg.JobPipeline
---@field job gg.Job|nil artifacts and below
---@field artifact gg.JobArtifact|nil artifacts and below
---@field archive boolean|nil an archive artifact (browsable)
---@field expired boolean|nil an expired artifact
---@field count integer|nil pipelines: the number of artifacts

---@alias gg.ui.ArchiveListing { status: "loading"|"listed"|"error", error?: string }

---@class gg.ui.ArtifactTree
---@field roots gg.ui.ArtifactNode[] newest pipeline first
---@field by_id table<string, gg.ui.ArtifactNode>
---@field listing table<integer, gg.ui.ArchiveListing> by job id (absent = not listed yet)
---@field total integer pipelines with artifacts before `max_roots`

---@class gg.ui.ArtifactBuildOpts
---@field now integer epoch seconds
---@field show_expired? boolean
---@field entries? table<integer, { path: string, size: integer|nil, type?: string }[]> archive entries by job id
---@field listing? table<integer, gg.ui.ArchiveListing>
---@field max_roots? integer keep only the newest pipelines (`total` still counts them all)

local function lower(s)
  return (s or ""):lower()
end

-- folders first, then files; each by name, case-insensitively
local function sort_entries(nodes)
  table.sort(nodes, function(a, b)
    if (a.kind == "dir") ~= (b.kind == "dir") then
      return a.kind == "dir"
    end
    if lower(a.name) ~= lower(b.name) then
      return lower(a.name) < lower(b.name)
    end
    return a.name < b.name
  end)
  for _, n in ipairs(nodes) do
    if n.kind == "dir" then
      sort_entries(n.children)
    end
  end
end

-- sum sizes and count files bottom-up
local function totals(node)
  if node.kind == "file" then
    return node.size or 0, 1
  end
  local size, files = 0, 0
  for _, c in ipairs(node.children) do
    local s, f = totals(c)
    size, files = size + s, files + f
  end
  node.size, node.files = size, files
  return size, files
end

-- attach archive entries below `art` as folders and files
local function attach_entries(tree, art, entries)
  local job_id = art.job.id
  local dirs = { [""] = art }
  local function dir(path)
    if dirs[path] then
      return dirs[path]
    end
    local parent_path, name = path:match("^(.*/)([^/]+)/$")
    if not name then
      parent_path, name = "", path:sub(1, -2)
    end
    local parent = dir(parent_path)
    local node = {
      id = ("d:%d:%s"):format(job_id, path),
      kind = "dir",
      name = name,
      path = path,
      children = {},
      parent = parent.id,
      pipeline = art.pipeline,
      job = art.job,
      artifact = art.artifact,
    }
    table.insert(parent.children, node)
    tree.by_id[node.id] = node
    dirs[path] = node
    return node
  end
  for _, e in ipairs(entries) do
    local path = (e.path or ""):gsub("^/+", "")
    if e.type == "directory" or path:sub(-1) == "/" then
      if path ~= "" then
        dir(path:sub(-1) == "/" and path or path .. "/")
      end
    elseif path ~= "" and not tree.by_id[("f:%d:%s"):format(job_id, path)] then
      local parent_path, name = path:match("^(.*/)([^/]+)$")
      local parent = dir(parent_path or "")
      local node = {
        id = ("f:%d:%s"):format(job_id, path),
        kind = "file",
        name = name or path,
        path = path,
        size = e.size,
        children = {},
        parent = parent.id,
        pipeline = art.pipeline,
        job = art.job,
        artifact = art.artifact,
      }
      table.insert(parent.children, node)
      tree.by_id[node.id] = node
    end
  end
  sort_entries(art.children)
  for _, c in ipairs(art.children) do
    if c.kind == "dir" then
      totals(c)
    end
  end
end

--- Build the tree from jobs (each with `pipeline` and `artifacts`, as from
--- `gg.jobs.list_project`). Job logs and archive metadata are left out;
--- expired artifacts too unless `show_expired`. Pipelines without any
--- artifact left are dropped.
---@param jobs gg.Job[]
---@param opts gg.ui.ArtifactBuildOpts
---@return gg.ui.ArtifactTree
function M.build(jobs, opts)
  local tree = { roots = {}, by_id = {}, listing = opts.listing or {} }
  local roots = {}
  local seen = {}
  for _, job in ipairs(jobs) do
    local p = job.pipeline
    if p and p.id and not seen[job.id] then
      seen[job.id] = true
      for _, a in ipairs(job.artifacts or {}) do
        local expired = expires.expired(a, opts.now)
        if not M.HIDDEN_TYPES[a.file_type] and (opts.show_expired or not expired) then
          local root = roots[p.id]
          if not root then
            root = { id = "p:" .. p.id, kind = "pipeline", name = "#" .. p.id, children = {}, pipeline = p, size = 0, count = 0 }
            roots[p.id] = root
            table.insert(tree.roots, root)
            tree.by_id[root.id] = root
          end
          local id = ("a:%d:%s"):format(job.id, a.file_type or "")
          if not tree.by_id[id] then
            local art = {
              id = id,
              kind = "artifact",
              name = a.filename or a.file_type or "?",
              size = a.size,
              children = {},
              parent = root.id,
              pipeline = p,
              job = job,
              artifact = a,
              archive = a.file_type == "archive",
              expired = expired or nil,
            }
            table.insert(root.children, art)
            tree.by_id[id] = art
            root.size = root.size + (a.size or 0)
            root.count = root.count + 1
            local entries = art.archive and not expired and opts.entries and opts.entries[job.id]
            if entries then
              attach_entries(tree, art, entries)
            end
          end
        end
      end
    end
  end
  table.sort(tree.roots, function(a, b)
    return a.pipeline.id > b.pipeline.id
  end)
  tree.total = #tree.roots
  if opts.max_roots and #tree.roots > opts.max_roots then
    local keep = vim.list_slice(tree.roots, 1, opts.max_roots)
    local kept = {}
    for _, r in ipairs(keep) do
      kept[r.pipeline.id] = true
    end
    for id, n in pairs(tree.by_id) do
      if not kept[n.pipeline.id] then
        tree.by_id[id] = nil
      end
    end
    tree.roots = keep
  end
  for _, root in ipairs(tree.roots) do
    table.sort(root.children, function(a, b)
      if lower(a.job.name) ~= lower(b.job.name) then
        return lower(a.job.name) < lower(b.job.name)
      end
      if a.job.id ~= b.job.id then
        return a.job.id > b.job.id
      end
      return a.id < b.id
    end)
  end
  return tree
end

--- True when the node can be opened: pipelines, folders, and archives that
--- have not expired (an archive's entries are fetched when it is opened).
---@param node gg.ui.ArtifactNode
---@return boolean
function M.expandable(node)
  if node.kind == "pipeline" or node.kind == "dir" then
    return true
  end
  return node.kind == "artifact" and node.archive == true and not node.expired
end

--- The listing state of an archive node ("unlisted" when never fetched).
---@param tree gg.ui.ArtifactTree
---@param node gg.ui.ArtifactNode
---@return "unlisted"|"loading"|"listed"|"error"
---@return string|nil error message
function M.listing(tree, node)
  local l = node.job and tree.listing[node.job.id]
  if not l then
    return "unlisted"
  end
  return l.status, l.error
end

--- The open set on first load: the newest pipeline, and the newest pipeline
--- on the default branch.
---@param tree gg.ui.ArtifactTree
---@param default_branch? string
---@return table<string, boolean>
function M.default_open(tree, default_branch)
  local open = {}
  if tree.roots[1] then
    open[tree.roots[1].id] = true
  end
  for _, r in ipairs(tree.roots) do
    if default_branch and r.pipeline.ref == default_branch and not r.pipeline.tag then
      open[r.id] = true
      break
    end
  end
  return open
end

--- The parent of a node (nil for a pipeline).
---@param tree gg.ui.ArtifactTree
---@param id string
---@return gg.ui.ArtifactNode|nil
function M.parent(tree, id)
  local n = tree.by_id[id]
  return n and n.parent and tree.by_id[n.parent] or nil
end

--- Open every pipeline and folder, and every archive whose entries are
--- already listed; archives not listed yet stay closed (no downloads).
---@param tree gg.ui.ArtifactTree
---@param open table<string, boolean> changed in place
function M.open_all(tree, open)
  for id, n in pairs(tree.by_id) do
    if n.kind == "pipeline" or n.kind == "dir" or (M.expandable(n) and M.listing(tree, n) == "listed") then
      open[id] = true
    end
  end
end

--- Every node below `node` that is a file, or the artifact itself when it
--- is a report (a single file).
---@param node gg.ui.ArtifactNode
---@return gg.ui.ArtifactNode[]
function M.files_below(node)
  local out = {}
  local function walk(n)
    if n.kind == "file" or (n.kind == "artifact" and not n.archive) then
      table.insert(out, n)
    end
    for _, c in ipairs(n.children) do
      walk(c)
    end
  end
  walk(node)
  return out
end

---@class gg.ui.ArtifactRow
---@field kind gg.ui.ArtifactNodeKind|"status"
---@field node gg.ui.ArtifactNode for "status": the archive it belongs to
---@field depth integer 0 for pipelines
---@field lasts boolean[] for depth 1..depth: whether that ancestor (or the row itself, last) is the last child
---@field open boolean|nil
---@field status? "loading"|"error" status rows
---@field error? string

--- The visible rows, top to bottom. `visible` (a set of ids) limits the
--- nodes shown, as the filter does; nil shows everything.
---@param tree gg.ui.ArtifactTree
---@param open table<string, boolean>
---@param visible? table<string, boolean>
---@return gg.ui.ArtifactRow[]
function M.flatten(tree, open, visible)
  local rows = {}
  local function shown(list)
    if not visible then
      return list
    end
    local out = {}
    for _, n in ipairs(list) do
      if visible[n.id] then
        table.insert(out, n)
      end
    end
    return out
  end
  local function walk(nodes, depth, lasts)
    local list = shown(nodes)
    for i, n in ipairs(list) do
      local my = vim.list_extend({}, lasts)
      if depth > 0 then
        table.insert(my, i == #list)
      end
      local is_open = M.expandable(n) and open[n.id] == true or nil
      table.insert(rows, { kind = n.kind, node = n, depth = depth, lasts = my, open = is_open })
      if is_open then
        local status, err = "listed", nil
        if n.kind == "artifact" then
          status, err = M.listing(tree, n)
        end
        if status == "loading" or status == "error" then
          local sl = vim.list_extend({}, my)
          table.insert(sl, true)
          table.insert(rows, { kind = "status", node = n, depth = depth + 1, lasts = sl, status = status, error = err })
        else
          walk(n.children, depth + 1, my)
        end
      end
    end
  end
  walk(tree.roots, 0, {})
  return rows
end

return M
