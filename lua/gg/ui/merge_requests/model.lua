--- Merge requests table model: tab + filter + order + pages. Pure.
---
--- One row per merge request, no grouping. "locked" counts as Open (it is a
--- transient state of an open MR).
local filter = require("gg.ui.merge_requests.filter")

local M = {}

---@alias gg.ui.MrTab "opened"|"merged"|"closed"|"all"

M.TABS = { "opened", "merged", "closed", "all" }
M.STATES = { "opened", "merged", "closed" }

---@class gg.ui.MrModel
---@field tab gg.ui.MrTab
---@field counts { opened: integer, merged: integer, closed: integer, all: integer } per tab, unfiltered
---@field matching integer rows in the active tab that match the filter
---@field total integer rows in the active tab
---@field filtered boolean a filter is active
---@field rows gg.MergeRequest[] matching rows, in order

---@class gg.ui.MrPage
---@field rows gg.MergeRequest[]
---@field count integer

--- The tab a merge request belongs to (besides All).
---@param mr gg.MergeRequest
---@return "opened"|"merged"|"closed"
function M.state_of(mr)
  if mr.state == "merged" or mr.state == "closed" then
    return mr.state
  end
  return "opened"
end

--- Default order: updated_at desc, then iid desc.
---@param a gg.MergeRequest
---@param b gg.MergeRequest
---@return boolean
function M.order(a, b)
  if a.updated_at ~= b.updated_at then
    return (a.updated_at or "") > (b.updated_at or "")
  end
  return (a.iid or 0) > (b.iid or 0)
end

--- Build the model for one tab and filter.
---@param mrs gg.MergeRequest[] every loaded merge request, all states
---@param opts { tab?: gg.ui.MrTab, query?: string }
---@return gg.ui.MrModel
function M.build(mrs, opts)
  local tab = opts.tab or "opened"
  local tokens = filter.parse(opts.query)
  local counts = { opened = 0, merged = 0, closed = 0, all = #mrs }
  local rows, total = {}, 0
  for _, mr in ipairs(mrs) do
    local state = M.state_of(mr)
    counts[state] = counts[state] + 1
    if tab == "all" or state == tab then
      total = total + 1
      if filter.matches(mr, tokens) then
        table.insert(rows, mr)
      end
    end
  end
  table.sort(rows, M.order)
  return { tab = tab, counts = counts, matching = #rows, total = total, filtered = #tokens > 0, rows = rows }
end

--- Pages of at most `size` rows; always at least one (possibly empty) page.
---@param rows gg.MergeRequest[]
---@param size integer
---@return gg.ui.MrPage[]
function M.pages(rows, size)
  size = math.max(1, size)
  local pages = { { rows = {}, count = 0 } }
  for _, mr in ipairs(rows) do
    local page = pages[#pages]
    if page.count >= size then
      page = { rows = {}, count = 0 }
      table.insert(pages, page)
    end
    table.insert(page.rows, mr)
    page.count = page.count + 1
  end
  return pages
end

--- The page that holds merge request `iid`, or nil.
---@param pages gg.ui.MrPage[]
---@param iid integer|nil
---@return integer|nil
function M.page_of(pages, iid)
  if iid == nil then
    return nil
  end
  for p, page in ipairs(pages) do
    for _, mr in ipairs(page.rows) do
      if mr.iid == iid then
        return p
      end
    end
  end
  return nil
end

return M
