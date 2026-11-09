-- The merge requests view end to end: real windows, fake backend.
local D = require("tests.support.mr_data")
local DI = require("tests.support.ui_data")
local H = require("tests.helpers")
local config = require("gg.ui.config")
local mr_view = require("gg.ui.merge_requests.view")
local eq = MiniTest.expect.equality

local current -- the view under test (its picker is closed after each case)
local saved = {}

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      saved = { columns = vim.o.columns, lines = vim.o.lines, notify = vim.notify, batch = mr_view.BATCH }
      vim.o.columns, vim.o.lines = 170, 40
    end,
    post_case = function()
      if current then
        current:close()
        current = nil
      end
      vim.notify = saved.notify
      mr_view.BATCH = saved.batch
      vim.o.columns, vim.o.lines = saved.columns, saved.lines
      config.setup()
      H.reset()
    end,
  },
})

local function open(cfg, responses)
  local fake = H.fake()
  fake:add(responses or D.all())
  local c = vim.tbl_deep_extend("force", config.get(), cfg or {})
  current = mr_view.open({ host = D.HOST, project = D.PROJECT, config = c })
  return current, fake
end

local function ready(v)
  H.wait_for(function()
    return v.status == "ready" and not v.pending.opened and not v.pending.merged and not v.pending.closed
  end)
  return v
end

-- every visible row has its summary
local function filled(v)
  H.wait_for(function()
    local page = v.pages[v.page]
    for _, mr in ipairs(page.rows) do
      if not v.cache[mr.iid] then
        return false
      end
    end
    return v.queue.running == 0
  end)
  return v
end

local function lines(v)
  return vim.api.nvim_buf_get_lines(v.table_float.buf, 0, -1, false)
end

local function cursor(v)
  return vim.api.nvim_win_get_cursor(v.table_float.win)[1]
end

local function keys(s)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(s, true, false, true), "x", false)
end

local function footer_text(v)
  local f = vim.api.nvim_win_get_config(v.table_float.win).footer
  return table.concat(vim.tbl_map(function(c)
    return c[1]
  end, f))
end

local function summary_requests(fake)
  return vim.tbl_filter(function(r)
    return r.operation == "MergeRequestSummaries"
  end, fake:requests())
end

T["opens, loads three states, rows first, cells fill in later"] = function()
  local v, fake = open(nil, D.all({ delay = 300 }))
  eq(lines(v)[5], "  Loading merge requests…")
  ready(v)
  local states = {}
  for _, rec in ipairs(fake:requests()) do
    if rec.operation == "MergeRequestsListProject" then
      eq({ rec.variables.fullPath, rec.variables.sort, rec.variables.first }, { D.PROJECT, "UPDATED_DESC", 20 })
      states[rec.variables.state] = true
    end
  end
  eq(states, { opened = true, merged = true, closed = true })
  local l = lines(v)
  eq(l[1], "  Open 6     Merged 2     Closed 1     All 9  ")
  eq(vim.startswith(l[5], "  !88   Rotate Terraform state backend credentials"), true)
  -- rows are there, the cells are still placeholders
  eq(l[5]:find("✓", 1, true), nil)
  eq(l[5]:find("·", 1, true) ~= nil, true)
  eq(cursor(v), 5)
  eq(v.selected_iid, 88)
  -- chrome
  eq(footer_text(v), " [i] Merge Request ")
  eq(vim.api.nvim_win_get_config(v.table_float.win).title[1][1], " Table ")
  local title = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, vim.api.nvim_win_get_config(v.filter_float.win).title))
  eq(title, " [/] Filter ")
  eq(vim.bo[v.table_float.buf].filetype, "gg_ui_merge_requests")
  -- one batch for the six open rows, asked for in page order
  filled(v)
  local reqs = summary_requests(fake)
  eq(#reqs, 1)
  eq(reqs[1].variables.iids, { "88", "87", "86", "85", "84", "83" })
  l = lines(v)
  eq(l[5]:find("✓ ✓ ✓ ▸", 1, true) ~= nil, true)
  eq(l[5]:find("+120   −34", 1, true) ~= nil, true)
  eq(l[7]:find("✓ ✗ ○ ○", 1, true) ~= nil, true)
end

T["filling cells never moves the cursor"] = function()
  local v = ready(open(nil, D.all({ delay = 300 })))
  keys("jj") -- !86
  eq(v.selected_iid, 86)
  local before = vim.api.nvim_win_get_cursor(v.table_float.win)
  filled(v)
  eq(vim.api.nvim_win_get_cursor(v.table_float.win), before)
  eq(v.selected_iid, 86)
  -- the overlay is still on the selected row
  local marks = vim.api.nvim_buf_get_extmarks(v.table_float.buf, v.shell.ns, 0, -1, { details = true })
  eq(#marks, 2)
  eq(marks[1][2], 6)
end

T["at most four summary requests run at a time"] = function()
  mr_view.BATCH = 1
  local v, fake = open(nil, D.all({ delay = 200 }))
  ready(v)
  H.wait_for(function()
    return v.queue.running == 4
  end)
  eq(v.queue:waiting(), 2)
  filled(v)
  eq(#summary_requests(fake), 6)
end

T["the cache avoids refetching; R refetches only active pipelines"] = function()
  local v, fake = open()
  filled(ready(v))
  eq(#summary_requests(fake), 1)
  keys("L") -- Merged: its two rows are fetched
  filled(v)
  eq(#summary_requests(fake), 2)
  keys("H") -- back to Open: cached
  H.flush(30)
  eq(#summary_requests(fake), 2)
  v.prompt:set_text("rotate")
  v.prompt:set_text("")
  H.flush(30)
  eq(#summary_requests(fake), 2)
  -- refresh: only !87 (pipeline running) is fetched again
  keys("R")
  ready(v)
  filled(v)
  local reqs = summary_requests(fake)
  eq(#reqs, 3)
  eq(reqs[3].variables.iids, { "87" })
end

T["a changed updated_at refetches that merge request"] = function()
  local v, fake = open()
  filled(ready(v))
  local nodes = D.nodes()
  nodes[5].updatedAt = "2026-11-09T00:00:00Z" -- !84 changed (and moves to the top)
  fake:reset()
  fake:add(D.list_responses(nodes, { ["repeat"] = true }))
  fake:add(D.summaries_response(nodes))
  fake:add(D.me_response())
  keys("R")
  ready(v)
  filled(v)
  -- !84 (changed) and !87 (pipeline still running); nothing else
  local asked = {}
  for _, rec in ipairs(summary_requests(fake)) do
    vim.list_extend(asked, rec.variables.iids)
  end
  table.sort(asked)
  eq(asked, { "84", "87" })
  eq(vim.startswith(lines(v)[5], "  !84"), true)
end

T["the signed-in user is bold"] = function()
  local v = filled(ready(open()))
  H.wait_for(function()
    return v.me == D.ME
  end)
  local bold = 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(v.table_float.buf, v.list.ns, 0, -1, { details = true })) do
    if m[4].hl_group == "GitlabCurrentUser" then
      bold = bold + 1
    end
  end
  eq(bold, 5) -- assignee of !88, !87, !86; reviewer of !85, !84
end

T["i and <CR> call on_inspect_mr"] = function()
  local got = {}
  local v = ready(open({
    on_inspect_mr = function(mr, ctx)
      table.insert(got, { mr.iid, ctx.host, ctx.project })
    end,
  }))
  keys("i")
  keys("j")
  keys("<CR>")
  eq(got, { { 88, D.HOST, D.PROJECT }, { 87, D.HOST, D.PROJECT } })
end

T["tabs, filter, paging"] = function()
  local v = filled(ready(open({ page_size = 4 })))
  eq(#v.pages, 2)
  eq(footer_text(v), " [i] Merge Request • [P] Page 1/2 ")
  keys("P")
  eq(v.page, 2)
  eq(v.selected_iid, 84)
  keys("L")
  eq(v.tab, "merged")
  keys("LL")
  eq(v.tab, "all")
  eq(lines(v)[1]:find("All 9", 1, true) ~= nil, true)
  keys("L")
  eq(v.tab, "opened")
  v.prompt:set_text("draft")
  eq(v.model.matching, 1)
  eq(v.selected_iid, 87)
  -- no match counter in this view
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(v.filter_float.buf, -1, 0, -1, { details = true })) do
    eq(m[4].virt_text_pos ~= "right_align", true)
  end
end

T["error state with retry, then R reloads"] = function()
  local fake = H.fake()
  fake:add({ request = { operation = "MergeRequestsListProject" }, response = { status = 500, body = { message = "boom" } } })
  fake:add(D.me_response())
  current = mr_view.open({ host = D.HOST, project = D.PROJECT, config = config.get() })
  local v = current
  H.wait_for(function()
    return v.status == "error"
  end)
  eq(vim.startswith(lines(v)[5], "  Failed to load merge requests:"), true)
  eq(lines(v)[6], "  [R] Retry")
  fake:reset():add(D.all())
  keys("R")
  ready(v)
  eq(v.model.counts.all, 9)
end

T["a failed summary request leaves placeholders until R"] = function()
  local fake = H.fake()
  fake:add(D.list_responses(nil, { ["repeat"] = true }))
  fake:add({ request = { operation = "MergeRequestSummaries" }, response = { status = 500, body = { message = "boom" } } })
  fake:add(D.me_response())
  current = mr_view.open({ host = D.HOST, project = D.PROJECT, config = config.get() })
  local v = filled(ready(current))
  eq(v.cache[88].error, true)
  eq(lines(v)[5]:find("✓", 1, true), nil)
  -- re-rendering does not retry
  v.prompt:set_text("x")
  v.prompt:set_text("")
  H.flush(30)
  eq(#summary_requests(fake), 1)
  fake:add(D.summaries_response())
  keys("R")
  ready(v)
  filled(v)
  eq(lines(v)[5]:find("✓", 1, true) ~= nil, true)
end

T["<Tab> cycles issues <-> merge requests in the same windows, keeping each view's state"] = function()
  local fake = H.fake()
  fake:add(DI.responses(nil, { ["repeat"] = true }))
  fake:add(D.all())
  current = require("gg.ui.issues.view").open({ host = D.HOST, project = D.PROJECT, today = DI.TODAY, config = config.get() })
  local issues = current
  H.wait_for(function()
    return issues.status == "ready" and not issues.pending.opened and not issues.pending.closed
  end)
  local win = issues.table_float.win
  keys("L") -- issues: Closed tab
  issues.prompt:set_text("rotate")
  eq(issues.tab, "closed")
  -- no MR request before the view is first shown
  eq(#vim.tbl_filter(function(r)
    return r.operation == "MergeRequestsListProject"
  end, fake:requests()), 0)

  keys("<Tab>")
  local mrs = issues.shell.views.merge_requests
  eq(issues.shell.active, mrs)
  eq(mrs.table_float.win, win) -- same windows
  ready(mrs)
  eq(issues.prompt:text(), "") -- the MR view's own (empty) filter
  eq(lines(mrs)[1], "  Open 6     Merged 2     Closed 1     All 9  ")
  eq(vim.bo[mrs.table_float.buf].filetype, "gg_ui_merge_requests")
  keys("jj")
  eq(mrs.selected_iid, 86)
  -- MR-specific keys are mapped; the issues' milestone jump is not
  eq(vim.fn.maparg("<CR>", "n", false, true).buffer, 1)
  eq(vim.fn.maparg("]m", "n", false, true).buffer, nil)

  keys("<Tab>")
  eq(issues.shell.active, issues)
  eq(issues.tab, "closed")
  eq(issues.query, "rotate")
  eq(issues.prompt:text(), "rotate")
  eq(vim.bo[issues.table_float.buf].filetype, "gg_ui_issues")
  eq(lines(issues)[1], "    Open 9     Closed 3     All 12  ")
  eq(vim.fn.maparg("]m", "n", false, true).buffer, 1)

  local list_requests = #vim.tbl_filter(function(r)
    return r.operation == "MergeRequestsListProject"
  end, fake:requests())
  keys("<S-Tab>")
  eq(issues.shell.active, mrs)
  eq(mrs.selected_iid, 86)
  eq(lines(mrs)[cursor(mrs)]:find("!86", 1, true) ~= nil, true)
  -- shown again from memory: no new list requests
  eq(#vim.tbl_filter(function(r)
    return r.operation == "MergeRequestsListProject"
  end, fake:requests()), list_requests)
  -- closing cancels both views
  issues:close()
  current = nil
  eq({ issues.closed, mrs.closed }, { true, true })
end

T["gg.ui.open can start on the merge requests view"] = function()
  H.fake():add(D.all())
  current = require("gg.ui").open({ host = D.HOST, project = D.PROJECT, view = "merge_requests" })
  ready(current)
  eq(current.name, "merge_requests")
  eq(current.model.counts.all, 9)
end

return T
