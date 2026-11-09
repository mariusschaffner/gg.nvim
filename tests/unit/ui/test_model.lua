-- gg.ui.issues: filter, model (grouping, ordering, counts, progress), paginate.
local D = require("tests.support.ui_data")
local filter = require("gg.ui.issues.filter")
local model = require("gg.ui.issues.model")
local paginate = require("gg.ui.issues.paginate")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

local function build(opts)
  opts = vim.tbl_extend("force", { today = D.TODAY }, opts or {})
  return model.build(opts.issues or D.issues(), opts)
end

-- { key = { iids } } per block
local function shape(m)
  return vim.tbl_map(function(b)
    return { b.key, vim.tbl_map(function(i)
      return i.iid
    end, b.issues) }
  end, m.blocks)
end

T["counts per tab, locked counts as open"] = function()
  local m = build()
  eq(m.counts, { opened = 9, closed = 3, all = 12 })
  local issues = D.issues()
  issues[1].state = "locked"
  eq(model.build(issues, { today = D.TODAY }).counts.opened, 9)
end

T["grouping and default order: top-level first, milestones by due date"] = function()
  local m = build()
  eq(shape(m), {
    { "top:220", { 220 } },
    { "top:198", { 198 } },
    { "ms:11", { 211, 214, 209, 205 } },
    { "ms:12", { 219, 218, 216 } },
  })
  eq({ m.matching, m.total, m.filtered }, { 9, 9, false })
  -- no "No milestone" group exists
  for _, b in ipairs(m.blocks) do
    eq(b.kind == "top" or b.milestone ~= nil, true)
  end
end

T["milestone info: name, due text, real progress from issue_stats"] = function()
  local info = build().blocks[3].milestone
  eq({ info.name, info.rest }, { "%2026.11", "Patch cycle" })
  eq(info.due, { text = "due Nov 20 · in 12d", tone = "normal" })
  eq(info.progress, { closed = 2, total = 6 })
  eq(info.ref.id, 11)
end

T["progress falls back to counting fetched issues (all states, any tab)"] = function()
  local issues = D.issues()
  for _, i in ipairs(issues) do
    if i.milestone then
      i.milestone.issue_stats = nil
    end
  end
  local m = model.build(issues, { tab = "opened", query = "~monitoring", today = D.TODAY })
  eq(m.blocks[1].milestone.progress, { closed = 2, total = 6 })
end

T["tabs: closed and all"] = function()
  eq(shape(build({ tab = "closed" })), { { "top:190", { 190 } }, { "ms:11", { 201, 202 } } })
  local all = build({ tab = "all" })
  eq(all.total, 12)
  eq(shape(all)[4], { "ms:11", { 201, 202, 211, 214, 209, 205 } })
end

T["ordering is configurable"] = function()
  local m = build({
    order = {
      top = function(a, b)
        return a.iid < b.iid
      end,
      milestones = function(a, b)
        return a.title > b.title
      end,
    },
  })
  eq(vim.tbl_map(function(b)
    return b.key
  end, m.blocks), { "top:198", "top:220", "ms:12", "ms:11" })
end

T["split_title"] = function()
  eq({ model.split_title("2026.11 Patch cycle") }, { "%2026.11", "Patch cycle" })
  eq({ model.split_title("v1") }, { "%v1", "" })
  eq({ model.split_title(nil) }, { "%", "" })
  -- no version-like first word: the whole title is the name
  eq({ model.split_title("Entwicklung & Deployment") }, { "%Entwicklung & Deployment", "" })
  eq({ model.split_title("  Sprint 12 ") }, { "%Sprint 12", "" })
  eq({ model.split_title("v1.2 Release  candidate") }, { "%v1.2", "Release  candidate" })
end

T["filter: tokens"] = function()
  eq(filter.parse(" ~Sec  %none @x #21 rotate ~ "), {
    { kind = "label", value = "sec" },
    { kind = "milestone", value = "none", none = true },
    { kind = "assignee", value = "x" },
    { kind = "iid", value = "21" },
    { kind = "text", value = "rotate" },
  })
end

T["filter: matching, AND, empty blocks hidden"] = function()
  local function iids(q)
    local out = {}
    for _, b in ipairs(build({ query = q }).blocks) do
      for _, i in ipairs(b.issues) do
        table.insert(out, i.iid)
      end
    end
    return out
  end
  eq(iids("~SEC"), { 214 })
  eq(iids("%none"), { 220, 198 })
  eq(iids("@none"), { 198, 205 })
  eq(iids("@user-l"), { 220, 209 })
  eq(iids("%cloud"), { 219, 218, 216 })
  eq(iids("#21"), { 211, 214, 219, 218, 216 })
  eq(iids("220"), { 220 })
  eq(iids("terraform module"), { 216 })
  eq(iids("rotate ~docs"), {})
  eq(iids("~"), iids(""))
  local m = build({ query = "~monitoring" })
  eq({ m.matching, m.total, m.filtered, #m.blocks }, { 1, 9, true, 1 })
end

T["paginate: whole blocks, split big ones, at least one page"] = function()
  local blocks = build().blocks -- sizes 1, 1, 4, 3
  local function counts(pages)
    return vim.tbl_map(function(p)
      return p.count
    end, pages)
  end
  eq(counts(paginate.paginate(blocks, 50)), { 9 })
  eq(counts(paginate.paginate(blocks, 5)), { 2, 4, 3 })
  local pages = paginate.paginate(blocks, 3)
  eq(counts(pages), { 2, 3, 1, 3 })
  eq(pages[3].blocks[1].continued, true)
  eq(pages[3].blocks[1].milestone.name, "%2026.11")
  eq(pages[2].blocks[1].continued, nil)
  eq(paginate.page_of(pages, 205), 3)
  eq(paginate.page_of(pages, 216), 4)
  eq(paginate.page_of(pages, 999), nil)
  eq(paginate.page_of(pages, nil), nil)
  local empty = paginate.paginate({}, 10)
  eq(#empty, 1)
  eq(empty[1].count, 0)
end

return T
