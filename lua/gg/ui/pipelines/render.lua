--- Render the pipelines table into lines, highlights and row metadata.
--- Pure.
---
--- One line per pipeline. Static content only: the cursor mark and row highlight are overlays the
--- picker draws from `rows[*].mark_col`. The MR cell shows "·" while the
--- open merge requests are still loading.
local columns = require("gg.ui.pipelines.columns")
local date = require("gg.ui.lib.date")
local grid = require("gg.ui.components.grid")
local line = require("gg.ui.lib.line")
local model = require("gg.ui.pipelines.model")
local pipeline_status = require("gg.ui.lib.pipeline_status")
local text = require("gg.ui.lib.text")

local M = {}

M.SHA = 8

local TABS = {
  { key = "all", label = "All" },
  { key = "running", label = "Running" },
  { key = "failed", label = "Failed" },
  { key = "passed", label = "Passed" },
}

---@class gg.ui.PipelineRenderInput
---@field width integer window width in cells
---@field status "loading"|"ready"|"error"
---@field tab gg.ui.PipelineTab
---@field model? gg.ui.PipelineModel nil before the first load
---@field id_width? integer width of the `#` column (see columns.id_width)
---@field ctx? gg.ui.PipelineCtx
---@field now integer epoch seconds, for the Started column
---@field utc_offset? integer local zone, seconds east of UTC
---@field error? string
---@field loaded? integer pipelines loaded
---@field retry_key? string|false

---@class gg.ui.PipelineRowInfo
---@field kind "tabs"|"blank"|"header"|"rule"|"pipeline"|"message"
---@field pipeline? gg.Pipeline
---@field mark_col? integer byte column of the 2-cell cursor-mark slot

local function header_line(cols)
  local started = cols.started and { col = cols.started.col + cols.started.width - text.width("Started") } or nil
  return grid.header_line({
    { cols.status, "Status" },
    { cols.id, "#" },
    { cols.ref, "Ref" },
    { cols.stages, "Stages" },
    { cols.mr, "MR" },
    { cols.source, "Source" },
    { cols.commit, "Commit" },
    { started, "Started" },
  })
end

--- The highlight of a ref: the default branch, a tag, or another branch.
---@param p gg.Pipeline
---@param ctx? gg.ui.PipelineCtx
---@return string
function M.ref_hl(p, ctx)
  if p.tag then
    return "GitlabRefTag"
  end
  if ctx and ctx.default_branch and p.ref == ctx.default_branch then
    return "GitlabRefDefault"
  end
  return "GitlabBranchSource"
end

--- The Started text: relative to `now`, from `started_at`, else `created_at`.
---@param p gg.Pipeline
---@param now integer
---@param utc_offset? integer
---@return string
function M.started(p, now, utc_offset)
  return date.relative(p.started_at or p.created_at, now, utc_offset)
end

local function commit_cell(l, p, width)
  local sha = p.short_sha or (p.sha and p.sha:sub(1, M.SHA)) or ""
  l:cell(sha, width, "GitlabSha")
end

local function pipeline_line(p, cols, input)
  local ctx = input.ctx
  local l = line.new()
  l:pad_to(cols.mark.col)
  local mark_col = l.bytes
  l:add(string.rep(" ", cols.mark.width))
  l:segments(pipeline_status.status_cell(p.status, p.warnings), cols.status.width)
  l:pad_to(cols.id.col)
  l:cell("#" .. tostring(p.id), cols.id.width, "GitlabIid")
  if cols.ref then
    l:pad_to(cols.ref.col)
    l:cell(text.clean(model.display_ref(p)), cols.ref.width, M.ref_hl(p, ctx))
  end
  l:pad_to(cols.stages.col)
  l:segments(pipeline_status.stages(p), cols.stages.width)
  if cols.mr then
    l:pad_to(cols.mr.col)
    local iid, loading = model.mr_of(p, ctx)
    if iid then
      l:cell("!" .. iid, cols.mr.width, "GitlabIid")
    elseif loading then
      l:cell(pipeline_status.PLACEHOLDER, cols.mr.width, "Comment")
    end
  end
  if cols.source then
    l:pad_to(cols.source.col)
    local label = model.source_label(p.source)
    l:cell(text.clean(label), cols.source.width, p.source == "schedule" and "GitlabPipelineSourceSchedule" or "GitlabPipelineSource")
  end
  l:pad_to(cols.commit.col)
  commit_cell(l, p, cols.commit.width)
  if cols.started then
    local s = text.truncate(M.started(p, input.now, input.utc_offset), cols.started.width)
    l:pad_to(cols.started.col + cols.started.width - text.width(s))
    l:add(s, "Comment")
  end
  return l, mark_col
end

--- Render the table.
---@param input gg.ui.PipelineRenderInput
---@return gg.ui.Rendered
function M.render(input)
  local cols = columns.layout(input.width, input.id_width)
  local out = grid.new(cols)
  grid.head(out, grid.tabs_line({
    tabs = TABS,
    active = input.tab,
    counts = input.model and input.model.counts or nil,
  }), header_line(cols))

  local mdl = input.model
  if grid.state(out, {
    status = input.status,
    noun = "pipelines",
    col = cols.status.col,
    has_model = mdl ~= nil,
    empty = not mdl or #mdl.rows == 0,
    pending = false,
    error = input.error,
    retry_key = input.retry_key,
    loaded = input.loaded,
  }) then
    return out
  end
  for _, p in ipairs(mdl.rows) do
    local l, mark_col = pipeline_line(p, cols, input)
    local lnum = grid.push(out, l, { kind = "pipeline", pipeline = p, mark_col = mark_col })
    table.insert(out.selectable, lnum)
  end
  return out
end

return M
