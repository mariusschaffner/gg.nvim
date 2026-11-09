--- Split model blocks into pages. Pure.
---
--- A page holds at most `size` issues. Blocks stay whole when they fit on a
--- fresh page; a block bigger than a page is split, and every part after the
--- first is marked `continued` (the renderer repeats the milestone cell).
local M = {}

---@class gg.ui.Page
---@field blocks gg.ui.Block[]
---@field count integer issues on the page

local function part(block, from, to, continued)
  local issues = {}
  for i = from, to do
    issues[#issues + 1] = block.issues[i]
  end
  return {
    kind = block.kind,
    key = block.key,
    milestone = block.milestone,
    issues = issues,
    continued = continued or nil,
  }
end

--- Pages of blocks; always at least one (possibly empty) page.
---@param blocks gg.ui.Block[]
---@param size integer issues per page (>= 1)
---@return gg.ui.Page[]
function M.paginate(blocks, size)
  size = math.max(1, size)
  local pages = { { blocks = {}, count = 0 } }
  local function current()
    return pages[#pages]
  end
  local function new_page()
    if current().count > 0 then
      table.insert(pages, { blocks = {}, count = 0 })
    end
  end
  for _, block in ipairs(blocks) do
    local n = #block.issues
    if n <= size then
      if current().count + n > size then
        new_page()
      end
      table.insert(current().blocks, block)
      current().count = current().count + n
    else
      new_page()
      local from = 1
      while from <= n do
        local to = math.min(n, from + size - 1)
        if from > 1 then
          new_page()
        end
        table.insert(current().blocks, part(block, from, to, from > 1))
        current().count = current().count + (to - from + 1)
        from = to + 1
      end
    end
  end
  return pages
end

--- The page that holds the issue `iid`, or nil.
---@param pages gg.ui.Page[]
---@param iid integer|nil
---@return integer|nil
function M.page_of(pages, iid)
  if iid == nil then
    return nil
  end
  for p, page in ipairs(pages) do
    for _, block in ipairs(page.blocks) do
      for _, issue in ipairs(block.issues) do
        if issue.iid == iid then
          return p
        end
      end
    end
  end
  return nil
end

return M
