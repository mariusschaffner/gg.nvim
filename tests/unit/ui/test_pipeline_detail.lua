-- The pipeline detail view: graph layout, log parsing, statuses (pure) and
-- the view end to end (live log, modes, timers).
local H = require("tests.helpers")
local X = require("tests.support.detail_data")
local config = require("gg.ui.config")
local date = require("gg.ui.lib.date")
local detail = require("gg.ui.detail")
local graph = require("gg.ui.detail.pipeline.graph")
local log_model = require("gg.ui.detail.pipeline.log_model")
local stack = require("gg.ui.components.stack")
local status = require("gg.ui.detail.pipeline.status")
local eq = MiniTest.expect.equality

local s
local saved = {}

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      saved = { columns = vim.o.columns, lines = vim.o.lines, utc = date.utc_offset }
      vim.o.columns, vim.o.lines = 170, 50
      date.utc_offset = function()
        return 0
      end
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

T["graph: junctions, connectors, viewport"] = function()
  eq(graph.junction(false, true, true, true), "┬")
  eq(graph.junction(true, false, false, true), "└")
  eq(graph.junction(true, true, true, false), "┤")
  eq(graph.junction(false, false, true, true), "─")
  local rows = graph.connector(1, 3)
  eq(vim.tbl_map(function(r)
    return r.glyph
  end, rows), { "┬", "│", "│", "├", "│", "│", "└" })
  -- everything fits
  eq({ graph.viewport(3, 200, 2) }, { 1, 3 })
  -- 120 cells: (120 - 18 + 6) / 34 = 3 stages
  eq({ graph.viewport(6, 120, 1) }, { 1, 3 })
  eq({ graph.viewport(6, 120, 5) }, { 3, 5 })
  eq({ graph.viewport(6, 120, 4, 3) }, { 3, 5 }) -- keeps the window while visible
  eq({ graph.viewport(6, 120, 2, 3) }, { 2, 4 })
end

T["graph: render with markers and job scrolling"] = function()
  local function job(name, st)
    return { name = name, status = st }
  end
  local stages = {}
  for i = 1, 6 do
    table.insert(stages, { name = "s" .. i, status = "success", jobs = { job("j" .. i, "success") } })
  end
  stages[5].jobs = { job("a", "success"), job("b", "failed"), job("c", "running") }
  local d, first = graph.render({ stages = stages, width = 120, selected = { stage = 5, job = 3 }, focus = true, now = 0, max_rows = 7 })
  eq(first, 3)
  eq(d.lines[2]:find("‹ 2 more", 1, true) ~= nil, true)
  eq(d.lines[2]:find("1 more ›", 1, true) ~= nil, true)
  -- two job rows fit: b and c, c selected (thick)
  eq(#d.lines, 7)
  eq(d.lines[6]:find("┃ ◐ c", 1, true) ~= nil, true)
  eq(d.lines[3]:find("✗ b", 1, true) ~= nil, true)
  -- the selected pill has no fill: no highlight on the spaces inside it
  for _, mk in ipairs(d.marks) do
    eq(mk.hl ~= "GitlabCursorLine", true)
  end
  local empty = graph.render({ stages = {}, width = 60, now = 0 })
  eq(vim.trim(empty.lines[1]), "No jobs in this pipeline yet.")
end

T["status: pills, badges, default job, elapsed"] = function()
  eq(status.pill("running")[1], " ◐ Running ")
  eq(status.pill("success")[1], " ✓ Passed ")
  eq(status.pill("created")[1], " ◷ Pending ")
  local b = status.job_badge({ status = "failed", allow_failure = true, duration = 12 }, 0)
  eq({ b.icon, b.right }, { "!", "12s" })
  b = status.job_badge({ status = "manual", playable = false }, 0)
  eq({ b.icon, b.dashed, b.right }, { "⏸", true, "blocked" })
  eq(status.elapsed({ status = "running", started_at = "2026-11-10T11:00:00Z" }, date.parse_time("2026-11-10T11:02:14Z")), 134)
  local stages = {
    { jobs = { { status = "success" } } },
    { jobs = { { status = "failed", allow_failure = true }, { status = "failed" } } },
  }
  eq({ status.default_job(stages) }, { 2, 2 })
  stages[1].jobs[2] = { status = "running" }
  eq({ status.default_job(stages) }, { 1, 2 })
  eq({ status.default_job({}) }, { nil, nil })
end

T["log model: chunks, sections, carriage returns, ANSI, tints"] = function()
  local m = log_model.new()
  -- split anywhere, even inside a CRLF
  local raw = X.LOG:gsub("\n", "\r\n")
  for i = 1, #raw, 7 do
    m:feed(raw:sub(i, i + 6))
  end
  m:finish()
  local d, folds = m:render()
  eq(d.lines, {
    "Running with gitlab-runner 18.5.0",
    "▾ Preparing environment · 3s",
    "Running on runner-abc",
    "$ molecule test",
    "progress 100%",
    "ERROR: something broke",
  })
  eq(folds, { { 2, 3 } })
  eq(m.first_error, 6)
  eq(d.line_hls, { { row = 5, hl = "GitlabLogErrorLine" } })
  local green
  for _, mk in ipairs(d.marks) do
    if mk.row == 3 then
      green = mk
    end
  end
  eq(green, { row = 3, col = 0, end_col = 15, hl = "GitlabAnsiGreen" })
  -- incomplete lines wait for the next chunk
  local m2 = log_model.new()
  m2:feed("partial")
  eq(#m2.lines, 0)
  m2:feed(" line\nnext")
  eq(m2.lines[1].text, "partial line")
  m2:finish()
  eq(m2.lines[2].text, "next")
  -- escape sequences other than colours go away
  eq(log_model.strip_controls("a\27[2Kb\27]0;title\7c\8d"), "abcd")
  eq({ log_model.ansi("\27[1mbold\27[22m \27[38;5;200mx\27[0m") }, { "bold x", { { 0, 4, "GitlabAnsiBold" } } })
  eq(log_model.first_diff({ "a", "b" }, { "a", "c", "d" }), 2)
  eq(log_model.first_diff({ "a" }, { "a" }), nil)
end

local function keys(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "x", false)
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function open(responses, cfg)
  local fake = H.fake()
  fake:add(responses)
  s = stack.new()
  detail.pipeline({
    stack = s,
    cfg = vim.tbl_extend("force", config.get(), cfg or {}),
    host = X.HOST,
    project = X.PROJECT,
    today = X.TODAY,
    now = function()
      return date.parse_time(X.NOW)
    end,
  }, { id = X.PIPELINE_ID })
  local g = s:top().group
  H.wait_for(function()
    local l = lines(vim.api.nvim_win_get_buf(g.members.content.win))
    return l[1] == "Running with gitlab-runner 18.5.0"
  end)
  return g, fake
end

T["view: header graph, the running job's log, following"] = function()
  local g = open({ X.pipeline_graph(nil, { ["repeat"] = true }), X.trace(102, X.LOG) }, { pipeline_detail_poll_ms = 0, job_log_poll_ms = 0 })
  local hl = lines(g.members.header.buf)
  eq(vim.startswith(hl[2], "  ◐ Running  Add HTTPS listener task #4821"), true)
  eq(vim.endswith(hl[2], "9:00 elapsed · 2/4 jobs"), true)
  eq(hl[4]:find("build ✓ 1:02", 1, true) ~= nil, true)
  eq(hl[6]:find("┃ ◐ molecule          2:14 ┃", 1, true) ~= nil, true)
  local title = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, vim.api.nvim_win_get_config(g.members.header.win).title))
  eq(vim.startswith(title, " pipelines › #4821 "), true)
  eq(vim.endswith(title, "⎇ main · a1f3c9e0 · user-1 · started 9m ago "), true)
  local win = g.members.content.win
  eq(vim.wo[win].number, true)
  -- following: the cursor sits on the last line
  eq(vim.api.nvim_win_get_cursor(win)[1], 6)
  local ct = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, vim.api.nvim_win_get_config(win).title))
  eq(ct, " ◐ molecule  ● following ")
  -- the section folds
  eq(vim.api.nvim_win_call(win, function()
    return vim.fn.foldlevel(2)
  end), 1)
  -- moving up stops following
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_win_get_buf(win) })
  ct = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, vim.api.nvim_win_get_config(win).title))
  eq(ct, " ◐ molecule ")
  keys("F")
  eq(vim.api.nvim_win_get_cursor(win)[1], 6)
  -- no fullscreen key any more
  eq(vim.fn.maparg("gz", "n", false, true).buffer, nil)
  local footer = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, vim.api.nvim_win_get_config(win).footer))
  eq(footer, " [F] Follow • [/] Search ")
end

T["view: graph keys pick jobs; <CR> / <Esc> switch modes"] = function()
  local g, fake = open({
    X.pipeline_graph(nil, { ["repeat"] = true }),
    X.trace(102, X.LOG, { ["repeat"] = true }),
    X.trace(103,"lint output\nfail\n"),
    X.trace(101, "built\n"),
  }, { pipeline_detail_poll_ms = 0, job_log_poll_ms = 0 })
  local win = g.members.content.win
  keys("j") -- graph mode: the next job of the stage
  H.wait_for(function()
    return lines(vim.api.nvim_win_get_buf(win))[1] == "lint output"
  end)
  eq(lines(g.members.header.buf)[9]:find("┃ ! lint", 1, true) ~= nil, true)
  keys("h") -- previous stage, job index clamped
  H.wait_for(function()
    return lines(vim.api.nvim_win_get_buf(win))[1] == "built"
  end)
  keys("l")
  H.wait_for(function()
    return #lines(vim.api.nvim_win_get_buf(win)) == 6
  end)
  keys("<CR>") -- into the log: j moves the cursor now
  local footer = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, vim.api.nvim_win_get_config(g.members.header.win).footer))
  eq(footer, " [<Esc>] Graph • [gX] Cancel pipeline ") -- the pipeline is running
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  keys("j")
  eq(vim.api.nvim_win_get_cursor(win)[1], 2)
  keys("<Esc>")
  footer = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, vim.api.nvim_win_get_config(g.members.header.win).footer))
  eq(footer, " [h/l] Stage • [j/k] Job • [<CR>] Log • [X] Cancel • [gX] Cancel pipeline ") -- molecule is running
  local traces = 0
  for _, r in ipairs(fake:requests()) do
    if r.path and r.path:find("/trace", 1, true) then
      traces = traces + 1
    end
  end
  eq(traces, 4) -- 102, 103, 101, then 102 again (new log state)
end

T["view: a running job's log is tailed; timers stop on q"] = function()
  local g = open({
    X.pipeline_graph(nil, { ["repeat"] = true }),
    X.trace(102, X.LOG),
    X.trace(102, "more output\n", { status = 206, headers = { ["Content-Range"] = "bytes 200-211/212" } }),
    X.trace(102, "", { status = 416, ["repeat"] = true }),
  }, { pipeline_detail_poll_ms = 0, job_log_poll_ms = 20 })
  local win = g.members.content.win
  H.wait_for(function()
    local l = lines(vim.api.nvim_win_get_buf(win))
    return l[#l] == "more output"
  end)
  eq(#lines(vim.api.nvim_win_get_buf(win)), 7)
  eq(vim.api.nvim_win_get_cursor(win)[1], 7) -- still following
  keys("q")
  eq(s:is_closed(), true)
  H.flush(60) -- no timer fires on a closed view (no error, no request)
end

T["view: the job finishing fetches the rest of its log once"] = function()
  local fake = H.fake()
  fake:add({
    X.pipeline_graph(),
    X.trace(102, X.LOG),
    X.pipeline_graph({ status = "failed", test_status = "failed" }, { ["repeat"] = true }),
    X.trace(102, "the end\n", { status = 206, headers = { ["Content-Range"] = "bytes 200-207/208" } }),
  })
  s = stack.new()
  detail.pipeline({ stack = s, cfg = vim.tbl_extend("force", config.get(), { pipeline_detail_poll_ms = 30, job_log_poll_ms = 0 }), host = X.HOST, project = X.PROJECT }, { id = X.PIPELINE_ID })
  local g = s:top().group
  local win = g.members.content.win
  H.wait_for(function()
    local l = lines(vim.api.nvim_win_get_buf(win))
    return l[#l] == "the end"
  end)
  H.wait_for(function()
    return lines(g.members.header.buf)[2]:find("✗ Failed", 1, true) ~= nil
  end)
  local n = 0
  for _, r in ipairs(fake:requests()) do
    if r.path and r.path:find("/trace", 1, true) then
      n = n + 1
    end
  end
  eq(n, 2)
end

T["view: job and pipeline actions, with confirmations"] = function()
  local jobs = "/api/v4/projects/" .. X.ENC .. "/jobs/"
  local job = function(id, name, st)
    return { body = { id = id, name = name, status = st, stage = "test", allow_failure = false, web_url = "https://gitlab.example.com/x" } }
  end
  local notes = {}
  local saved = { notify = vim.notify, input = vim.ui.input }
  vim.notify = function(msg)
    table.insert(notes, msg)
  end
  vim.ui.input = function(_, cb)
    cb("y")
  end
  local ok, err = pcall(function()
    local g, fake = open({
      X.pipeline_graph(nil, { ["repeat"] = true }),
      X.trace(102, X.LOG, { ["repeat"] = true }),
      X.trace(103, "lint" .. string.char(10), { ["repeat"] = true }),
      { request = { method = "POST", path = jobs .. "103/retry" }, response = job(105, "lint", "pending") },
      { request = { method = "POST", path = jobs .. "104/play" }, response = job(104, "deploy-prod", "pending") },
      { request = { method = "POST", path = jobs .. "102/cancel" }, response = job(102, "molecule", "canceled") },
      { request = { method = "POST", path = "/api/v4/projects/" .. X.ENC .. "/pipelines/4821/cancel" }, response = { body = { id = 4821, status = "canceled", ref = "main", sha = "a1f3c9e0" } } },
    }, { pipeline_detail_poll_ms = 0, job_log_poll_ms = 0 })
    local function posted(path)
      for _, r in ipairs(fake:requests()) do
        if r.method == "POST" and r.path == path then
          return true
        end
      end
      return false
    end
    -- the failed lint job: [r] Retry in the hints, r retries it
    keys("j")
    local hfoot = table.concat(vim.tbl_map(function(c)
      return c[1]
    end, vim.api.nvim_win_get_config(g.members.header.win).footer))
    eq(hfoot:find("[r] Retry", 1, true) ~= nil, true)
    keys("r")
    H.wait_for(function()
      return posted(jobs .. "103/retry")
    end)
    -- the manual deploy job: play
    keys("l")
    keys("p")
    H.wait_for(function()
      return posted(jobs .. "104/play")
    end)
    -- the running molecule job: cancel asks first
    keys("hk")
    keys("X")
    H.wait_for(function()
      return posted(jobs .. "102/cancel")
    end)
    -- the pipeline: retry is refused while it runs, cancel asks first
    keys("gR")
    eq(notes[#notes], "gg.ui: Pipeline #4821 has no failed jobs to retry")
    keys("gX")
    H.wait_for(function()
      return posted("/api/v4/projects/" .. X.ENC .. "/pipelines/4821/cancel")
    end)
    H.wait_for(function()
      return vim.tbl_contains(notes, "gg.ui: Pipeline #4821 canceled")
    end)
  end)
  vim.notify, vim.ui.input = saved.notify, saved.input
  assert(ok, err)
end

return T
