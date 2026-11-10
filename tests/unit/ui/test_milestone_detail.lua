-- The milestone detail view: the date strip and buckets (pure), and the
-- view end to end with real windows and the fake backend.
local H = require("tests.helpers")
local X = require("tests.support.detail_data")
local config = require("gg.ui.config")
local date = require("gg.ui.lib.date")
local detail = require("gg.ui.detail")
local render = require("gg.ui.detail.milestone.render")
local stack = require("gg.ui.components.stack")
local text = require("gg.ui.lib.text")
local timeline = require("gg.ui.detail.milestone.timeline")
local eq = MiniTest.expect.equality

local s
local saved = {}

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      saved = { columns = vim.o.columns, lines = vim.o.lines, utc = date.utc_offset }
      vim.o.columns, vim.o.lines = 170, 50
    end,
    post_case = function()
      if s and not s:is_closed() then
        s:close()
      end
      s = nil
      date.utc_offset = saved.utc
      vim.o.columns, vim.o.lines = saved.columns, saved.lines
      config.setup()
      H.reset()
    end,
  },
})

local TODAY = { year = 2026, month = 11, day = 10 }

T["pill and bar state"] = function()
  local m = { state = "active", start_date = "2026-11-02", due_date = "2026-11-20" }
  eq(timeline.pill(m, TODAY)[1], " ● Active ")
  eq({ timeline.bar_state(m, TODAY) }, { "in_progress", nil })
  eq(timeline.pill({ state = "active", start_date = "2026-11-12" }, TODAY)[1], " ● Upcoming ")
  eq({ timeline.bar_state({ state = "active", start_date = "2026-11-12", due_date = "2026-11-30" }, TODAY) }, { "before_start", 2 })
  eq(timeline.pill({ state = "active", due_date = "2026-11-01" }, TODAY)[1], " ● Overdue ")
  eq({ timeline.bar_state({ state = "active", due_date = "2026-11-01", created_at = "2026-10-01T00:00:00Z" }, TODAY) }, { "overdue", 9 })
  eq(timeline.pill({ state = "closed" }, TODAY)[1], " ● Closed ")
  eq({ timeline.bar_state({ state = "active" }, TODAY) }, { "no_dates", nil })
  -- without a start date, the creation date starts the strip
  local start = timeline.range({ due_date = "2026-11-20", created_at = "2026-10-20T09:00:00Z" })
  eq(start, { year = 2026, month = 10, day = 20 })
end

T["strip: ticks on Mondays, the today marker, labels"] = function()
  local m = { state = "active", start_date = "2026-11-02", due_date = "2026-11-15" }
  local d = timeline.strip(m, TODAY, 44) -- 42 cells of strip
  eq(#d.lines, 3)
  eq(d.lines[1], " │02.11.              │09.11.       15.11.│")
  eq(text.width(d.lines[2]), 43)
  local marker = timeline.column(TODAY, date.parse("2026-11-02"), date.parse("2026-11-15"), 42)
  eq(marker, 24)
  eq(vim.fn.strcharpart(d.lines[2], 1 + marker, 1), "┃")
  eq(vim.fn.strcharpart(d.lines[2], 1, 1), "━")
  eq(vim.fn.strcharpart(d.lines[2], 2 + marker, 1), "─")
  eq(d.lines[3], " " .. string.rep(" ", marker - 2) .. "today")
  -- colliding labels are dropped, ticks stay
  local tight = timeline.ticks(date.parse("2026-11-01"), date.parse("2026-12-20"), 30)
  local str = tight:result()
  eq(vim.endswith(str, "20.12.│"), true)
  eq(select(2, str:gsub("│", "")) >= 6, true)
  -- the date labels are regions (the overlays of gs / gd anchor on them)
  eq(d.lines[1]:sub(d.regions.start_date.col + 1, d.regions.start_date.col + 6), "02.11.")
  eq(d.lines[1]:sub(d.regions.due_date.col + 1, d.regions.due_date.col + 6), "15.11.")
  local none = timeline.strip({ state = "active" }, TODAY, 40)
  eq(none.lines, { " no dates" })
  eq(none.regions.start_date, { row = 0, col = 1, width = 8, height = 1 })
  eq(timeline.strip({ state = "closed", start_date = "2026-10-01", due_date = "2026-10-31" }, TODAY, 40).lines[3], " closed 31.10.")
  eq(timeline.strip({ state = "active", start_date = "2026-11-12", due_date = "2026-11-30" }, TODAY, 40).lines[3], " starts in 2 days")
end

T["buckets and counts"] = function()
  local function issue(state, labels, assignees)
    return {
      state = state,
      labels = vim.tbl_map(function(n)
        return { name = n }
      end, labels),
      assignees = assignees or {},
    }
  end
  eq(render.bucket(issue("closed", { "WF:Doing" })), "done")
  eq(render.bucket(issue("opened", { "wf: doing" })), "doing")
  eq(render.bucket(issue("opened", { "WF::Done" })), "done")
  eq(render.bucket(issue("opened", { "WF:To do" })), "todo")
  eq(render.bucket(issue("opened", { "bug" })), "todo")
  local c = render.counts({ issue("closed", {}), issue("opened", { "WF:Doing" }, { { username = "a" } }), issue("opened", {}) })
  eq({ c.done, c.doing, c.todo, c.total, c.unassigned, #c.in_progress }, { 1, 1, 1, 3, 1, 1 })
end

local function keys(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "x", false)
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function open()
  date.utc_offset = function()
    return 0
  end
  local fake = H.fake()
  fake:add(X.milestone_responses())
  s = stack.new()
  detail.milestone({
    stack = s,
    cfg = config.get(),
    host = X.HOST,
    project = X.PROJECT,
    today = X.TODAY,
    now = function()
      return date.parse_time(X.NOW)
    end,
  }, { id = 11, title = "2026.11 Patch cycle" })
  local g = s:top().group
  H.wait_for(function()
    local side = lines(g.members.sidebar.buf)
    local tab3 = lines(s:top().group.members.content.buf)
    return side[2] == " PROGRESS" and side[3] ~= " Loading…" and #tab3 > 2
  end)
  H.wait_for(function()
    return lines(g.members.header.buf)[2]:find("Patch cycle", 1, true) ~= nil and #lines(g.members.header.buf) == 7
  end)
  return g, fake
end

T["view: header strip, sidebar buckets, description"] = function()
  local g, fake = open()
  local hl = lines(g.members.header.buf)
  eq(hl[1], "")
  eq(vim.startswith(hl[2], "  ● Active  2026.11 Patch cycle %11"), true)
  eq(vim.startswith(hl[4], " │02.11."), true)
  eq(vim.endswith(hl[4], "20.11.│"), true)
  eq(vim.trim(hl[6]), "today")
  eq(hl[7], "")
  local title = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, vim.api.nvim_win_get_config(g.members.header.win).title))
  eq(vim.startswith(title, " milestones › %11 "), true)
  eq(vim.endswith(title, " project milestone · updated 1d ago "), true)
  local side = lines(g.members.sidebar.buf)
  eq(side[4], " 2/6 closed")
  eq(side[8], " ◐ Doing                      2")
  eq(side[10], " unassigned                   1")
  eq(side[14], " IN PROGRESS")
  eq(lines(g.members.content.buf), { "", " Patch everything.", "", " ✓ hypervisors", " ○ hosts" })
  local footer = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, vim.api.nvim_win_get_config(g.members.content.win).footer))
  eq(footer, " [i] Edit ")
  -- the issues asked for the milestone's title, in every state
  for _, r in ipairs(fake:requests()) do
    if r.operation == "IssuesListProject" then
      eq({ r.variables.milestoneTitle, r.variables.state }, { { "2026.11 Patch cycle" }, "all" })
    end
  end
  local tabs = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, vim.api.nvim_win_get_config(g.members.content.win).title))
  eq(tabs, " Description · Work items · Merge requests ") -- no counts
end

T["view: work items and merge requests tables open their detail views"] = function()
  local g = open()
  keys("<Tab>")
  local win = g.members.content.win
  local l = lines(vim.api.nvim_win_get_buf(win))
  -- one table of every issue: no Open / Closed / All line
  eq(l[1], "")
  eq(vim.trim(l[2]):sub(1, 5), "Issue")
  eq(#l, 3 + 6)
  eq(l[4]:find("#214  Rotate Terraform state backend credentials", 1, true) ~= nil, true)
  eq(vim.api.nvim_win_get_cursor(win)[1], 4)
  keys("j")
  eq(vim.api.nvim_win_get_cursor(win)[1], 5)
  local footer = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, vim.api.nvim_win_get_config(win).footer))
  eq(footer, " [i] Issue ")
  local got = {}
  local real = { issue = detail.issue, merge_request = detail.merge_request }
  detail.issue = function(ctx, issue)
    got.issue = { issue.iid, ctx.project }
  end
  detail.merge_request = function(_, mr)
    got.mr = mr.iid
  end
  local ok, err = pcall(function()
    keys("i")
    keys("<Tab>")
    local mrl = lines(vim.api.nvim_win_get_buf(win))
    eq(mrl[2]:find("Title", 1, true) ~= nil, true) -- no state tabs here either
    eq(mrl[4]:find("!88", 1, true) ~= nil, true)
    keys("j")
    keys("<CR>")
  end)
  detail.issue, detail.merge_request = real.issue, real.merge_request
  assert(ok, err)
  eq(got, { issue = { 211, X.PROJECT }, mr = 87 })
end

T["view: narrow puts the counts in the header"] = function()
  vim.o.columns = 90
  date.utc_offset = function()
    return 0
  end
  local fake = H.fake()
  fake:add(X.milestone_responses())
  s = stack.new()
  detail.milestone({ stack = s, cfg = config.get(), host = X.HOST, project = X.PROJECT, today = X.TODAY }, { id = 11, title = "2026.11 Patch cycle" })
  local g = s:top().group
  eq(g.members.sidebar, nil)
  H.wait_for(function()
    return lines(g.members.header.buf)[3] == " 2/6 closed · 2 doing · 1 unassigned · 2 MRs"
  end)
end

return T
