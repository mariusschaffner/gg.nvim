--- Cell contents of the merge requests table: the diff column (numbers +
--- bar). Pure; every function returns segments `{ text, hl }` the renderer
--- appends. The pipeline stage icons are `gg.ui.lib.pipeline_status`.
local text = require("gg.ui.lib.text")

local M = {}

M.PLACEHOLDER = "·"
M.MINUS = "−" -- U+2212
M.BAR = "━" -- a thin line, like the issues' milestone progress bar
M.BAR_CELLS = 8
M.NUMBER_CELLS = 5

--- A count in at most 4 characters: 9999, then 12k, 123k, 1M.
---@param n integer
---@return string
function M.compact(n)
  n = math.max(0, math.floor(n or 0))
  if n <= 9999 then
    return tostring(n)
  end
  if n < 1000000 then
    return math.floor(n / 1000) .. "k"
  end
  return math.min(999, math.floor(n / 1000000)) .. "M"
end

--- Green cells of the bar: round(add / (add + del) * cells), at least one
--- per non-zero side.
---@param add integer
---@param del integer
---@param cells? integer default BAR_CELLS
---@return integer green
function M.bar_split(add, del, cells)
  cells = cells or M.BAR_CELLS
  local total = add + del
  if total <= 0 then
    return 0
  end
  local green = math.floor(add / total * cells + 0.5)
  if add > 0 then
    green = math.max(1, green)
  end
  if del > 0 then
    green = math.min(cells - 1, green)
  end
  return green
end

--- True for GitLab's "no stats" value: when it has no line counts for a
--- merge request (no diff refs, nothing from Gitaly) `diffStatsSummary` is
--- 0 / 0 with 0 files, the same as an empty diff.
---@param stats gg.DiffStatsSummary|nil
---@return boolean
function M.is_nil_stats(stats)
  return stats ~= nil and stats.additions == 0 and stats.deletions == 0 and (stats.file_count or 0) == 0
end

--- Line counts from per-file stats (`gg.mr_changes.diffstat`); files whose
--- counts GitLab withheld (too large, collapsed) are left out.
---@param files gg.DiffStat[]
---@return { additions: integer, deletions: integer }
function M.sum_stats(files)
  local add, del = 0, 0
  for _, f in ipairs(files) do
    add = add + (f.additions or 0)
    del = del + (f.deletions or 0)
  end
  return { additions = add, deletions = del }
end

local function right(s, width)
  local w = text.width(s)
  return w < width and string.rep(" ", width - w) .. s or s
end

--- The diff cell: "+add" and "−del" right-aligned in fixed slots, then the
--- bar when `with_bar`. `·` placeholders while loading, on an error, and in
--- the bar when both counts are 0.
---@param stats gg.DiffStatsSummary|nil
---@param st? gg.ui.CellState
---@param with_bar boolean
---@return gg.ui.Segment[]
function M.diff(stats, st, with_bar)
  local n = M.NUMBER_CELLS
  local out = {}
  if not stats or (st and (st.loading or st.failed)) then
    table.insert(out, { right(M.PLACEHOLDER, n), "Comment" })
    table.insert(out, { " ", nil })
    table.insert(out, { right(M.PLACEHOLDER, n), "Comment" })
    if with_bar then
      table.insert(out, { " ", nil })
      table.insert(out, { string.rep(M.PLACEHOLDER, M.BAR_CELLS), "Comment" })
    end
    return out
  end
  local add, del = stats.additions or 0, stats.deletions or 0
  table.insert(out, { right("+" .. M.compact(add), n), "GitlabDiffAdd" })
  table.insert(out, { " ", nil })
  table.insert(out, { right(M.MINUS .. M.compact(del), n), "GitlabDiffDelete" })
  if with_bar then
    table.insert(out, { " ", nil })
    if add + del == 0 then
      table.insert(out, { string.rep(M.PLACEHOLDER, M.BAR_CELLS), "Comment" })
    else
      local green = M.bar_split(add, del)
      table.insert(out, { string.rep(M.BAR, green), "GitlabDiffAdd" })
      table.insert(out, { string.rep(M.BAR, M.BAR_CELLS - green), "GitlabDiffDelete" })
    end
  end
  return out
end

return M
