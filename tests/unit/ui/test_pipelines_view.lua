-- The pipelines view end to end: real windows, fake backend.
local D = require("tests.support.pipeline_data")
local H = require("tests.helpers")
local MR = require("tests.support.mr_data")
local config = require("gg.ui.config")
local pl_view = require("gg.ui.pipelines.view")
local eq = MiniTest.expect.equality

local current -- the view under test (its picker is closed after each case)
local saved = {}

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      saved = { columns = vim.o.columns, lines = vim.o.lines, notify = vim.notify, started = pl_view.STARTED_MS }
      vim.o.columns, vim.o.lines = 170, 40
    end,
    post_case = function()
      if current then
        current:close()
        current = nil
      end
      vim.notify = saved.notify
      pl_view.STARTED_MS = saved.started
      vim.o.columns, vim.o.lines = saved.columns, saved.lines
      config.setup()
      H.reset()
    end,
  },
})

local function open(cfg, responses)
  local fake = H.fake()
  fake:add(responses or D.all({ now = os.time() }))
  local c = vim.tbl_deep_extend("force", config.get(), { pipeline_refresh_ms = 0 }, cfg or {})
  current = pl_view.open({ host = D.HOST, project = D.PROJECT, config = c })
  return current, fake
end

local function ready(v)
  H.wait_for(function()
    return v.status == "ready"
  end)
  return v
end

-- the project and the open merge requests have arrived
local function filled(v)
  H.wait_for(function()
    return v.ctx.default_branch ~= nil and v.ctx.mr_by_branch ~= nil
  end)
  return v
end

local function lines(v)
  return vim.api.nvim_buf_get_lines(v.shell.table_float.buf, 0, -1, false)
end

local function cursor(v)
  return vim.api.nvim_win_get_cursor(v.shell.table_float.win)[1]
end

local function keys(s)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(s, true, false, true), "x", false)
end

local function footer_text(v)
  local f = vim.api.nvim_win_get_config(v.shell.table_float.win).footer
  return table.concat(vim.tbl_map(function(c)
    return c[1]
  end, f))
end

local function line_of(v, id)
  for i, l in ipairs(lines(v)) do
    if l:find("#" .. id, 1, true) then
      return i, l
    end
  end
end

T["rows show at once; the MR column and the ref colour fill in without moving the cursor"] = function()
  local v = open(nil, D.all({ now = os.time(), mr_delay = 300, project_delay = 300 }))
  ready(v)
  local l = lines(v)
  eq(l[1], "  All 8     Running 1     Failed 2     Passed 3  ")
  eq(l[5]:find("◐ running", 1, true) ~= nil, true)
  eq(l[5]:find("a1f3c9e0 Add HTTPS listener task", 1, true) ~= nil, true)
  eq(l[5]:find("✓ ◐ ○ ○", 1, true) ~= nil, true)
  eq(l[5]:sub(-#"2m ago"), "2m ago")
  -- still loading: "·" in the MR column of branch pipelines; MR pipelines know theirs
  eq(l[5]:find("·", 1, true) ~= nil, true)
  eq(select(2, line_of(v, 4815)):find("!85", 1, true) ~= nil, true)
  eq(footer_text(v), " [i] Pipeline ")
  keys("jj")
  eq(cursor(v), 7)
  eq(v.selected_id, 4817)
  local before = #l
  filled(v)
  H.flush(20)
  l = lines(v)
  eq(#l, before)
  eq(cursor(v), 7) -- the cursor did not move
  eq(v.selected_id, 4817)
  eq(l[5]:find("!87", 1, true) ~= nil, true)
  eq(l[7]:find("!88", 1, true) ~= nil, true)
  eq(l[5]:find("·", 1, true), nil)
  -- main is the default branch now
  local main_row = select(1, line_of(v, 4812)) - 1
  local hls = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(v.shell.table_float.buf, v.list.ns, { main_row, 0 }, { main_row, -1 }, { details = true })) do
    hls[m[4].hl_group or ""] = true
  end
  eq(hls.GitlabRefDefault, true)
  -- a thin separator below every row
  local virt = vim.api.nvim_buf_get_extmarks(v.shell.table_float.buf, v.list.ns, 0, -1, { details = true })
  eq(#vim.tbl_filter(function(m)
    return m[4].virt_lines ~= nil
  end, virt), 8)
end

T["P appends the next page and keeps the selection"] = function()
  local v, fake = open(nil, D.all({ now = os.time(), next_cursor = "c1" }))
  ready(v)
  eq(footer_text(v), " [i] Pipeline • [P] More ")
  eq(lines(v)[1]:find("(first 8)", 1, true) ~= nil, true)
  keys("jjj")
  local at = cursor(v)
  eq(v.selected_id, 4815)
  keys("P")
  H.wait_for(function()
    return #v.pipelines == 10
  end)
  H.flush(20)
  eq(cursor(v), at)
  eq(v.selected_id, 4815)
  eq(#v.rendered.selectable, 10)
  eq(lines(v)[1], "  All 10     Running 1     Failed 2     Passed 5  ")
  eq(footer_text(v), " [i] Pipeline ")
  local last = fake:last()
  eq({ last.operation, last.variables.after }, { "PipelinesListProject", "c1" })
  -- no further page: P does nothing
  local n = #fake:requests()
  keys("P")
  H.flush(20)
  eq(#fake:requests(), n)
end

T["active pipelines refresh live, update their line in place, then the timer stops"] = function()
  local now = os.time()
  local done = D.specs()[1]
  done.status, done.stages = "success", { "success", "success", "success", "success" }
  local responses = D.all({ now = now })
  table.insert(responses, D.refresh_response({ 4821 }, { done }, { now = now }))
  local v, fake = open({ pipeline_refresh_ms = 40 }, responses)
  filled(ready(v))
  eq(v.refresh_timer ~= nil, true)
  keys("jj")
  local at = cursor(v)
  H.wait_for(function()
    local _, l = line_of(v, 4821)
    return l and l:find("✓ passed", 1, true) ~= nil
  end)
  eq(cursor(v), at)
  eq(v.selected_id, 4817)
  local _, l = line_of(v, 4821)
  eq(l:find("✓ ✓ ✓ ✓", 1, true) ~= nil, true)
  eq(lines(v)[1], "  All 8     Running 0     Failed 2     Passed 4  ")
  -- nothing shown is active any more
  H.wait_for(function()
    return v.refresh_timer == nil
  end)
  local refreshes = vim.tbl_filter(function(r)
    return r.variables and r.variables.ids ~= nil
  end, fake:requests())
  eq(#refreshes, 1)
  eq(refreshes[1].variables.ids, { "gid://gitlab/Ci::Pipeline/4821" })
end

T["a pipeline leaving the active tab redraws and keeps the selection"] = function()
  local now = os.time()
  local done = D.specs()[1]
  done.status = "success"
  local responses = D.all({ now = now })
  table.insert(responses, D.refresh_response({ 4821 }, { done }, { now = now }))
  local v = open({ pipeline_refresh_ms = 40 }, responses)
  filled(ready(v))
  keys("H") -- All -> Passed (previous tab)
  eq(v.tab, "passed")
  keys("L") -- back to All
  keys("L") -- Running
  eq(v.tab, "running")
  eq(#v.rendered.selectable, 1)
  H.wait_for(function()
    return v.model and v.model.counts.running == 0
  end)
  eq(#v.rendered.selectable, 0)
  eq(lines(v)[5]:find("No pipelines match", 1, true) ~= nil, true)
end

T["the timers stop when the picker closes or the view is switched away"] = function()
  pl_view.STARTED_MS = 30
  local fake = H.fake()
  fake:add(D.all({ now = os.time() }))
  fake:add(MR.all())
  local v = pl_view.open({ host = D.HOST, project = D.PROJECT, config = vim.tbl_deep_extend("force", config.get(), { pipeline_refresh_ms = 5000 }) })
  current = v
  ready(v)
  eq({ v.refresh_timer ~= nil, v.started_timer ~= nil }, { true, true })
  keys("<S-Tab>") -- pipelines -> merge requests
  eq(v.shell.active.name, "merge_requests")
  H.wait_for(function()
    return v.started_timer == nil and v.refresh_timer == nil
  end)
  keys("<Tab>") -- back: the timers resume
  eq(v.shell.active, v)
  eq({ v.refresh_timer ~= nil, v.started_timer ~= nil }, { true, true })
  v:close()
  current = nil
  eq({ v.closed, v.refresh_timer, v.started_timer }, { true, nil, nil })
end

T["the Started column is redrawn by its own clock"] = function()
  pl_view.STARTED_MS = 30
  local v = open(nil, D.all({ now = os.time() - 61 }))
  ready(v)
  eq(lines(v)[5]:sub(-#"3m ago"), "3m ago")
  -- pretend a minute passed: the next tick rewrites the line
  local real = os.time
  os.time = function(t)
    return t and real(t) or real() + 60
  end
  H.wait_for(function()
    return lines(v)[5]:sub(-#"4m ago") == "4m ago"
  end)
  os.time = real
end

T["filter, tabs and i"] = function()
  local got
  local v = open({ on_inspect_pipeline = function(p, ctx)
    got = { p.id, ctx.project }
  end })
  filled(ready(v))
  v.shell.prompt:set_text("status:failed")
  H.wait_for(function()
    return v.query == "status:failed"
  end)
  eq(#v.rendered.selectable, 2)
  v.shell.prompt:set_text("!87")
  H.wait_for(function()
    return v.query == "!87"
  end)
  eq(#v.rendered.selectable, 1)
  v.shell.prompt:set_text("")
  H.wait_for(function()
    return v.query == ""
  end)
  keys("L")
  eq(v.tab, "running")
  keys("L")
  eq({ v.tab, #v.rendered.selectable }, { "failed", 2 })
  keys("i")
  eq(got, { 4819, D.PROJECT })
end

T["error state, then R reloads"] = function()
  local fake = H.fake()
  fake:add({ request = { operation = "PipelinesListProject" }, response = { status = 500, body = { message = "boom" } } })
  fake:add(D.project_response())
  fake:add(D.mrs_response())
  local v = pl_view.open({ host = D.HOST, project = D.PROJECT, config = config.get() })
  current = v
  H.wait_for(function()
    return v.status == "error"
  end)
  eq(lines(v)[5]:find("Failed to load pipelines", 1, true) ~= nil, true)
  fake:add(D.list_responses({ now = os.time() }))
  keys("R")
  ready(v)
  eq(#v.rendered.selectable, 8)
end

T["gg.ui.open can start on the pipelines view; it is in the <Tab> cycle"] = function()
  local fake = H.fake()
  fake:add(D.all({ now = os.time() }))
  fake:add(MR.all())
  current = require("gg.ui").open({ host = D.HOST, project = D.PROJECT, view = "pipelines" })
  eq(current.name, "pipelines")
  ready(current)
  eq(vim.bo[current.shell.table_float.buf].filetype, "gg_ui_pipelines")
  keys("<S-Tab>")
  eq(current.shell.active.name, "merge_requests")
  keys("<Tab>")
  eq(current.shell.active, current)
  eq(require("gg.ui.components.picker").VIEWS, { "issues", "merge_requests", "pipelines" })
end

return T
