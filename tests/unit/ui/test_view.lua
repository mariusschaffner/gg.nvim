-- The issues picker end to end: real windows, fake backend.
local D = require("tests.support.ui_data")
local H = require("tests.helpers")
local config = require("gg.ui.config")
local view = require("gg.ui.issues.view")
local eq = MiniTest.expect.equality

local current -- the view under test (closed after each case)
local saved = {}

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      saved = { columns = vim.o.columns, lines = vim.o.lines, notify = vim.notify }
      vim.o.columns, vim.o.lines = 170, 40
    end,
    post_case = function()
      if current then
        current:close()
        current = nil
      end
      vim.notify = saved.notify
      vim.o.columns, vim.o.lines = saved.columns, saved.lines
      config.setup()
      H.reset()
    end,
  },
})

local function open(cfg, response, extra)
  local fake = H.fake()
  fake:add(response or D.response(nil, { ["repeat"] = true }))
  local c = vim.tbl_deep_extend("force", config.get(), cfg or {})
  current = view.open(vim.tbl_extend("force", { host = D.HOST, project = D.PROJECT, today = D.TODAY, config = c }, extra or {}))
  return current, fake
end

local function ready(v)
  H.wait_for(function()
    return v.status == "ready"
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

T["opens two floats, loads every state once, renders the table"] = function()
  local v, fake = open()
  -- synchronous first frame: loading state
  eq(lines(v)[5], "  Loading issues…")
  ready(v)
  local rec = fake:last()
  eq(rec.operation, "IssuesListProject")
  eq({ rec.variables.fullPath, rec.variables.state, rec.variables.sort, rec.variables.first }, { D.PROJECT, "all", "MILESTONE_DUE_ASC", 100 })
  eq(lines(v)[1], " Open 9   Closed 3   All 12 ")
  eq(vim.startswith(lines(v)[7], "▎ %2026.11 Patch cycle"), true)
  -- the cursor starts on the first issue, not on the header
  eq(cursor(v), 5)
  eq(v.selected_iid, 220)
  eq(vim.api.nvim_get_current_win(), v.table_float.win)
  -- windows: full width, filter on top, table below
  local fc, tc = vim.api.nvim_win_get_config(v.filter_float.win), vim.api.nvim_win_get_config(v.table_float.win)
  eq({ fc.width, fc.height, tc.width, tc.height }, { 168, 1, 168, 40 - 1 - 3 - 1 - 2 })
  eq(footer_text(v), " [I] Milestone • [i] Issue ")
  local title = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, fc.title))
  eq(title, " [/] Filter ")
  eq(vim.wo[v.table_float.win].cursorline, false)
end

T["overlay: cursor mark, row highlight, active milestone edge"] = function()
  local v = ready(open())
  local function overlay()
    return vim.api.nvim_buf_get_extmarks(v.table_float.buf, v.ns, 0, -1, { details = true })
  end
  eq(#overlay(), 2) -- top-level row: row highlight + mark, no edge
  keys("jj") -- onto #211, the first issue of %2026.11
  eq(v.selected_iid, 211)
  local marks = overlay()
  local edges, mark = 0, nil
  for _, m in ipairs(marks) do
    if m[4].hl_group == "GitlabMilestoneEdgeActive" then
      edges = edges + 1
    elseif m[4].virt_text then
      mark = m
    end
  end
  eq(edges, 4) -- every line of the block
  eq(mark[4].virt_text, { { "▌", "GitlabCursorMark" } })
  eq(mark[2], 6) -- 0-based row of line 7
end

T["L / H switch tabs; the counts stay"] = function()
  local v = ready(open())
  keys("L")
  eq(v.tab, "closed")
  eq(lines(v)[5]:find("#190", 1, true) ~= nil, true)
  keys("L")
  eq(v.tab, "all")
  keys("L")
  eq(v.tab, "opened")
  keys("H")
  eq(v.tab, "all")
  eq(lines(v)[1], " Open 9   Closed 3   All 12 ")
end

T["the selection survives filtering and re-renders"] = function()
  local v = ready(open())
  keys("jjjj") -- #209
  eq(v.selected_iid, 209)
  v.prompt:set_text("monitor")
  eq(v.model.matching, 1)
  eq(v.selected_iid, 209)
  v.prompt:set_text("")
  eq(v.selected_iid, 209)
  eq(lines(v)[cursor(v)]:find("#209", 1, true) ~= nil, true)
  -- gone from the result: the nearest remaining line (#209 was on line 9;
  -- %2026.12 now spans lines 5-8, so its last issue, #216 on line 7, is nearest)
  v.prompt:set_text("%cloud")
  eq(v.selected_iid, 216)
end

T["filter: live through the prompt buffer, counter, Esc Esc clears"] = function()
  local v = ready(open({ filter_debounce_ms = 1 }))
  keys("/")
  eq(vim.api.nvim_get_current_win(), v.filter_float.win)
  vim.api.nvim_buf_set_lines(v.filter_float.buf, 0, -1, false, { "~oci" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = v.filter_float.buf })
  H.wait_for(function()
    return v.query == "~oci"
  end)
  eq(v.model.matching, 2)
  local counter
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(v.filter_float.buf, -1, 0, -1, { details = true })) do
    if m[4].virt_text_pos == "right_align" then
      counter = m[4].virt_text[1][1]
    end
  end
  eq(counter, "2 / 9")
  -- <CR> back to the table, filter kept
  vim.cmd("stopinsert")
  keys("<CR>")
  eq(vim.api.nvim_get_current_win(), v.table_float.win)
  eq(v.query, "~oci")
  keys("/")
  keys("<Esc><Esc>")
  eq(v.query, "")
  eq(vim.api.nvim_get_current_win(), v.table_float.win)
end

T["paging: P cycles and wraps, footer shows the page"] = function()
  local v = ready(open({ page_size = 3 }))
  eq(#v.pages, 4)
  eq(footer_text(v), " [I] Milestone • [i] Issue • [P] Page 1/4 ")
  keys("P")
  eq(v.page, 2)
  eq(v.selected_iid, 211)
  keys("PPP")
  eq(v.page, 1)
  eq(footer_text(v):find("Page 1/4", 1, true) ~= nil, true)
  -- a filter that matches an issue on another page follows the selection
  keys("PP") -- page 3: #205
  eq(v.selected_iid, 205)
  v.prompt:set_text("~")
  eq(v.page, 3)
end

T["]m / [m jump between milestone blocks"] = function()
  local v = ready(open())
  keys("]m")
  eq(v.selected_iid, 211)
  keys("]m")
  eq(v.selected_iid, 219)
  keys("]m")
  eq(v.selected_iid, 219)
  keys("[m")
  eq(v.selected_iid, 211)
end

T["i / I call the inspect callbacks; no milestone notifies"] = function()
  local got = {}
  local v = ready(open({
    on_inspect_issue = function(issue, ctx)
      got.issue, got.ctx = issue, ctx
    end,
    on_inspect_milestone = function(m)
      got.milestone = m
    end,
  }))
  local notes = {}
  vim.notify = function(msg)
    table.insert(notes, msg)
  end
  keys("i")
  eq(got.issue.iid, 220)
  eq({ got.ctx.host, got.ctx.project, type(got.ctx.close) }, { D.HOST, D.PROJECT, "function" })
  keys("I")
  eq(notes, { "No milestone" })
  eq(got.milestone, nil)
  keys("jj")
  keys("I")
  eq(got.milestone.title, "2026.11 Patch cycle")
  eq(got.milestone.issue_stats, { total = 6, closed = 2 })
  -- ctx.close closes the picker
  got.ctx.close()
  eq(v.closed, true)
  current = nil
end

T["keymaps are configurable and false disables one"] = function()
  local v = ready(open({ keymaps = { close = false, next_tab = "]t" } }))
  eq(vim.fn.maparg("q", "n", false, true).buffer, nil)
  eq(vim.fn.maparg("]t", "n", false, true).buffer, 1)
  keys("]t")
  eq(v.tab, "closed")
end

T["error state with retry, then R reloads"] = function()
  local v, fake = open({}, D.response(nil, { response = { status = 500, body = { message = "boom" } } }))
  H.wait_for(function()
    return v.status == "error"
  end)
  local l = lines(v)
  eq(vim.startswith(l[5], "  Failed to load issues:"), true)
  eq(l[6], "  [R] Retry")
  eq(cursor(v) >= 1, true)
  fake:add(D.response())
  keys("R")
  ready(v)
  eq(v.model.counts.all, 12)
end

T["refresh keeps the rows and says so in the title; close cancels the request"] = function()
  local nodes = D.nodes()
  local v, fake = open()
  ready(v)
  fake:reset():add(D.response(nodes, { response = { delay = 300, body = { data = { project = { issues = { nodes = { nodes[1] }, pageInfo = { hasNextPage = false } } } } } } }))
  keys("R")
  eq(v.status, "loading")
  local title = vim.api.nvim_win_get_config(v.table_float.win).title
  eq(title[1][1], " Table · refreshing… ")
  eq(lines(v)[5]:find("#220", 1, true) ~= nil, true) -- rows kept
  local task = v.task
  v:close()
  current = nil
  eq(task:is_cancelled(), true)
  H.flush(50)
end

T["empty result and resize re-render"] = function()
  local v = ready(open({}, D.response({})))
  eq(lines(v)[5], "  No issues match")
  eq(lines(v)[1], " Open 0   Closed 0   All 0 ")
  vim.o.columns = 90 -- fires VimResized
  H.flush(20)
  eq(#lines(v)[4], #"─" * 88)
end

T["opens from a project argument (single configured host)"] = function()
  H.fake():add(D.response())
  local c = config.get()
  current = view.open({ arg = D.PROJECT, today = D.TODAY, config = c })
  ready(current)
  eq({ current.host, current.project }, { D.HOST, D.PROJECT })
end

T["a bad project argument shows the error state"] = function()
  H.fake({}, { hosts = { ["gitlab.example.com"] = { token = "x" }, ["gl.example.org"] = { token = "y" } } })
  current = view.open({ arg = "a/b", today = D.TODAY })
  H.wait_for(function()
    return current.status == "error"
  end)
  eq(lines(current)[5]:find("several hosts", 1, true) ~= nil, true)
end

T["closing either window closes both"] = function()
  local v = ready(open())
  local tw = v.table_float.win
  vim.api.nvim_win_close(v.filter_float.win, true)
  H.wait_for(function()
    return v.closed
  end)
  eq(vim.api.nvim_win_is_valid(tw), false)
  current = nil
end

T["gg.ui.open with host + project"] = function()
  H.fake():add(D.response())
  current = require("gg.ui").open({ host = D.HOST, project = D.PROJECT })
  ready(current)
  eq(current.model.counts.all, 12)
end

return T
