--- Render the artifacts tree into lines, highlights and row metadata. Pure.
---
--- No tabs line: a blank line, the column header (Name, Size, Expires) and
--- the rule, then one line per visible node. Nested rows carry tree guides
--- ("rounded branches"), nodes that can be opened a chevron. Between two
--- pipelines a thin separator is drawn as a virtual line. The cursor mark
--- and row highlight are overlays the picker draws from `rows[*].mark_col`.
local columns = require("gg.ui.artifacts.columns")
local date = require("gg.ui.lib.date")
local expires = require("gg.ui.artifacts.expires")
local grid = require("gg.ui.components.grid")
local line = require("gg.ui.lib.line")
local model = require("gg.ui.artifacts.model")
local pipeline_status = require("gg.ui.lib.pipeline_status")
local size = require("gg.ui.lib.size")
local text = require("gg.ui.lib.text")

local M = {}

M.GUIDE = { vert = "│   ", blank = "    ", mid = "├── ", last = "╰── " }
M.CHEVRON = { open = "▾ ", closed = "▸ " }
M.LOADING = "◐ loading…"
M.FAILED = "✗"

--- File name extension -> highlight group (§4.1 of the spec).
M.EXT_HL = {
  md = "GitlabFileMarkdown",
  xml = "GitlabFileData",
  json = "GitlabFileData",
  yml = "GitlabFileData",
  yaml = "GitlabFileData",
  sarif = "GitlabFileSecurity",
  gz = "GitlabFileArchive",
  tgz = "GitlabFileArchive",
  zip = "GitlabFileArchive",
  tar = "GitlabFileArchive",
  tf = "GitlabFileCode",
  hcl = "GitlabFileCode",
  env = "GitlabFileEnv",
}

---@class gg.ui.ArtifactRenderInput
---@field width integer window width in cells
---@field status "loading"|"ready"|"error"
---@field tree? gg.ui.ArtifactTree nil before the first load
---@field open table<string, boolean> open node ids (with the filter's auto-opens)
---@field visible? table<string, boolean> the filter's visible ids; nil = all
---@field default_branch? string
---@field now integer epoch seconds
---@field utc_offset? integer
---@field error? string
---@field retry_key? string|false
---@field loaded? integer pipelines loaded so far
---@field icon_of? fun(name: string): string|nil, string|nil a file icon and its highlight

---@class gg.ui.ArtifactRowInfo
---@field kind "blank"|"header"|"rule"|"message"|gg.ui.ArtifactNodeKind|"status"
---@field node? gg.ui.ArtifactNode
---@field mark_col? integer byte column of the 2-cell cursor-mark slot

--- The highlight of a file name, by extension.
---@param name string
---@return string|nil
function M.ext_hl(name)
  local ext = (name or ""):match("%.([%w]+)$")
  return ext and M.EXT_HL[ext:lower()] or nil
end

--- The highlight of a pipeline's ref.
---@param p gg.JobPipeline
---@param default_branch? string
---@return string
function M.ref_hl(p, default_branch)
  if p.tag then
    return "GitlabRefTag"
  end
  if default_branch and p.ref == default_branch then
    return "GitlabRefDefault"
  end
  return "GitlabBranchSource"
end

--- The guide prefix of a row.
---@param row gg.ui.ArtifactRow
---@return string
function M.guide(row)
  if row.depth == 0 then
    return ""
  end
  local parts = {}
  for k = 1, row.depth - 1 do
    table.insert(parts, row.lasts[k] and M.GUIDE.blank or M.GUIDE.vert)
  end
  table.insert(parts, row.lasts[row.depth] and M.GUIDE.last or M.GUIDE.mid)
  return table.concat(parts)
end

local function header_line(cols)
  local size_col = cols.size and { col = cols.size.col + cols.size.width - text.width("Size") } or nil
  return grid.header_line({
    { cols.name, "Name" },
    { size_col, "Size" },
    { cols.expires, "Expires" },
  })
end

local function name_with_icon(segs, name, hl, input)
  if input.icon_of then
    local icon, icon_hl = input.icon_of(name)
    if icon and icon ~= "" then
      table.insert(segs, { icon .. " ", icon_hl })
    end
  end
  table.insert(segs, { text.clean(name), hl })
end

local function content(row, input)
  local n = row.node
  local segs = {}
  if row.kind ~= "status" and model.expandable(n) then
    table.insert(segs, { row.open and M.CHEVRON.open or M.CHEVRON.closed, "GitlabTreeChevron" })
  end
  if row.kind == "status" then
    if row.status == "loading" then
      table.insert(segs, { M.LOADING, "Comment" })
    else
      local msg = ("%s %s · "):format(M.FAILED, text.clean(row.error or "failed"))
      table.insert(segs, { msg, "DiagnosticError" })
      if input.retry_key then
        table.insert(segs, { "[" .. input.retry_key .. "]", "GitlabHintKey" })
        table.insert(segs, { " retry", "GitlabHintText" })
      end
    end
  elseif row.kind == "pipeline" then
    local p = n.pipeline
    local glyph, hl = pipeline_status.icon(p.status)
    table.insert(segs, { glyph .. " ", hl })
    table.insert(segs, { n.name, "GitlabTreeRoot" })
    table.insert(segs, { "  " .. text.clean(p.ref or ""), M.ref_hl(p, input.default_branch) })
    local when = date.relative(p.created_at, input.now, input.utc_offset)
    local count = ("%d artifact%s"):format(n.count, n.count == 1 and "" or "s")
    table.insert(segs, { (when ~= "" and ("  · " .. when) or "") .. "  · " .. count, "Comment" })
  elseif row.kind == "artifact" then
    local dead = n.expired and "GitlabArtifactExpired" or nil
    table.insert(segs, { text.clean(n.job.name or ""), dead or "GitlabArtifactJob" })
    table.insert(segs, { "  › ", dead or "Comment" })
    name_with_icon(segs, n.name, dead or M.ext_hl(n.name), input)
  elseif row.kind == "dir" then
    table.insert(segs, { text.clean(n.name) .. "/", "GitlabTreeDir" })
    if not row.open and n.files then
      table.insert(segs, { ("  %d file%s"):format(n.files, n.files == 1 and "" or "s"), "Comment" })
    end
  else
    name_with_icon(segs, n.name, M.ext_hl(n.name), input)
  end
  return segs
end

local function row_line(row, cols, input)
  local l = line.new()
  l:pad_to(cols.mark.col)
  local mark_col = l.bytes
  l:add(string.rep(" ", cols.mark.width))
  l:pad_to(cols.name.col)
  local segs = content(row, input)
  local guide = M.guide(row)
  if guide ~= "" then
    table.insert(segs, 1, { guide, "GitlabTreeGuide" })
  end
  l:segments(segs, cols.name.width)
  if row.kind ~= "status" then
    local n = row.node
    if cols.size and n.size then
      local s = size.human(n.size)
      l:pad_to(cols.size.col + cols.size.width - text.width(s))
      l:add(s)
    end
    if cols.expires and row.kind == "artifact" then
      local s, hl = expires.cell(n.artifact, input.now)
      l:pad_to(cols.expires.col)
      l:cell(s, cols.expires.width, hl)
    end
  end
  return l, mark_col
end

--- Render the table.
---@param input gg.ui.ArtifactRenderInput
---@return gg.ui.Rendered
function M.render(input)
  local cols = columns.layout(input.width)
  local out = grid.new(cols)
  grid.head(out, nil, header_line(cols))
  local tree = input.tree
  local rows = tree and model.flatten(tree, input.open or {}, input.visible) or {}
  if grid.state(out, {
    status = input.status,
    noun = "artifacts",
    col = cols.name.col,
    has_model = tree ~= nil,
    empty = #rows == 0,
    pending = false,
    error = input.error,
    retry_key = input.retry_key,
    loaded = input.loaded,
  }) then
    return out
  end
  local prev
  for _, row in ipairs(rows) do
    if row.kind == "pipeline" and prev then
      grid.separator(out, prev)
    end
    local l, mark_col = row_line(row, cols, input)
    local lnum = grid.push(out, l, { kind = row.kind, node = row.node, mark_col = mark_col })
    if row.kind ~= "status" then
      table.insert(out.selectable, lnum)
    end
    prev = lnum
  end
  return out
end

return M
