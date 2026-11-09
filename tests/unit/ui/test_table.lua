-- The shared table pieces: column engine, grid builder, filter tokenizer,
-- list items, task queue, list patching, prompt placeholder, new config keys.
local H = require("tests.helpers")
local columns = require("gg.ui.components.columns")
local config = require("gg.ui.config")
local filter = require("gg.ui.lib.filter")
local grid = require("gg.ui.components.grid")
local line = require("gg.ui.lib.line")
local list_buffer = require("gg.ui.components.list_buffer")
local prompt = require("gg.ui.components.prompt")
local queue = require("gg.ui.components.queue")
local task = require("gg.core.task")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      config.setup()
    end,
  },
})

T["columns engine: flex column, gaps, cumulative steps"] = function()
  local spec = {
    columns = {
      { name = "a", width = 4 },
      { name = "t", flex = true, min = 10 },
      { name = "b", width = 6, gap = 2 },
      { name = "c", width = 5, gap = 1 },
    },
    steps = { { hide = { "b" } }, { width = { c = 2 } } },
  }
  local l = columns.layout(40, spec)
  eq({ l.a, l.t, l.b, l.c }, { { col = 0, width = 4 }, { col = 4, width = 22 }, { col = 28, width = 6 }, { col = 35, width = 5 } })
  l = columns.layout(27, spec) -- step 1: b hidden
  eq({ l.b, l.t.width, l.c.col }, { nil, 17, 22 })
  l = columns.layout(16, spec) -- step 2 on top: c shrinks
  eq({ l.b, l.t.width, l.c }, { nil, 10, { col = 15, width = 2 } })
  l = columns.layout(5, spec) -- nothing fits: the minimum stays
  eq(l.t.width, 10)
end

T["grid: tab_pending, tabs line, header, states"] = function()
  local p = { opened = false, merged = true, closed = false }
  eq(grid.tab_pending(p, "opened"), false)
  eq(grid.tab_pending(p, "merged"), true)
  eq(grid.tab_pending(p, "all"), true)
  eq(grid.tab_pending({ opened = false }, "all"), false)
  eq(grid.tab_pending(p, "x", { x = { "closed", "merged" } }), true)
  eq(grid.tab_pending(nil, "all"), false)
  local s = grid.tabs_line({ tabs = { { key = "a", label = "A" }, { key = "b", label = "B" } }, active = "b", counts = { a = 1, b = 2 }, pending = { a = true }, indent = 1, pad = 1 }):result()
  eq(s, "  A 1…   B 2 ")
  eq((grid.header_line({ { { col = 3 }, "X" }, { nil, "hidden" }, { { col = 6 }, "Y" } }):result()), "   X  Y")
  local out = grid.new({ width = 10 })
  eq(grid.state(out, { status = "ready", noun = "things", col = 1, has_model = true, empty = false, pending = false }), false)
  eq(grid.state(out, { status = "ready", noun = "things", col = 1, has_model = true, empty = true, pending = false }), true)
  eq(out.lines, { " No things match" })
end

T["lib.filter: prefixes, none, lone prefixes, matchers"] = function()
  local spec = { prefixes = { ["@"] = "user", ["~"] = "label" }, none = { user = true } }
  eq(filter.parse(" @NONE ~x ~ y ", spec), {
    { kind = "user", value = "none", none = true },
    { kind = "label", value = "x" },
    { kind = "text", value = "y" },
  })
  local m = {
    text = function(item, t)
      return filter.contains(item.title, t.value)
    end,
  }
  eq(filter.matches({ title = "Hello" }, filter.parse("hell", spec), m), true)
  eq(filter.matches({ title = "Hello" }, filter.parse("~x", spec), m), false) -- no label matcher
  eq(filter.iid_starts(123, "12"), true)
  eq(filter.iid_starts(123, "1a"), false)
end

T["line:items: space separated, cut with …, layered highlight, exact width"] = function()
  local l = line.new():items({ { "@aa", "A", "Bold" }, { "@bbbb", "B" }, { "@c", "C" } }, 7)
  local s, marks = l:result()
  eq(s, "@aa @b…")
  eq(marks, {
    { col = 0, end_col = 3, hl = "A" },
    { col = 0, end_col = 3, hl = "Bold" },
    { col = 4, end_col = 4 + #"@b…", hl = "B" },
  })
  eq(line.new():items({ { "@x", "X" } }, 6):add("|").cells, 7)
  eq((line.new():items({ { "@aa" }, { "@b" } }, 4):add("|"):result()), "@aa |")
end

-- a task resolved by hand
local function manual()
  local resolve
  local t = task.new(function(res)
    resolve = res
  end)
  return t, function(v)
    resolve(v)
  end
end

T["queue: concurrency limit, de-duplication, order, clear, cancel"] = function()
  local q = queue.new({ concurrency = 2 })
  local started, done, resolvers, tasks = {}, {}, {}, {}
  local function push(key)
    return q:push(key, function()
      table.insert(started, key)
      local t, r = manual()
      resolvers[key], tasks[key] = r, t
      return t
    end, function(res)
      table.insert(done, res)
    end)
  end
  eq(push("a"), true)
  eq(push("b"), true)
  eq(push("c"), true)
  eq(push("a"), false) -- running
  eq(push("c"), false) -- queued
  eq(started, { "a", "b" })
  eq({ q.running, q:waiting(), q:has("c") }, { 2, 1, true })
  resolvers.a("A")
  H.wait_for(function()
    return #done == 1
  end)
  eq(done, { "A" })
  eq(started, { "a", "b", "c" })
  push("d")
  q:clear() -- d never starts
  eq({ q:waiting(), q:has("d") }, { 0, false })
  q:cancel_all()
  eq(tasks.b:is_cancelled(), true)
  eq(tasks.c:is_cancelled(), true)
  eq(q.running, 0)
  resolvers.b("B")
  H.flush(20)
  eq(done, { "A" }) -- cancelled tasks never call back
end

T["list_buffer:patch rewrites only the given lines and keeps the cursor"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  local l = list_buffer.new({ buf = buf, win = vim.api.nvim_get_current_win() })
  l:set({
    lines = { "head", "one ·", "two ·" },
    marks = { { row = 1, col = 4, end_col = #"one ·", hl = "Comment" }, { row = 2, col = 4, end_col = #"two ·", hl = "Comment" } },
    virt_lines = { { row = 1, chunks = { { "--", "Comment" } } }, { row = 2, chunks = { { "--", "Comment" } } } },
    selectable = { 2, 3 },
  })
  l:select(3)
  l:patch({
    lines = { "head", "one ✓", "two ✓" },
    marks = { { row = 1, col = 4, end_col = #"one ✓", hl = "DiagnosticOk" }, { row = 2, col = 4, end_col = #"two ✓", hl = "DiagnosticOk" } },
    virt_lines = { { row = 1, chunks = { { "--", "Comment" } } }, { row = 2, chunks = { { "--", "Comment" } } } },
    selectable = { 2, 3 },
  }, { 2 })
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "head", "one ✓", "two ·" })
  eq(vim.bo[buf].modifiable, false)
  eq(vim.api.nvim_win_get_cursor(0)[1], 3)
  local hls, virts = {}, 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, l.ns, 0, -1, { details = true })) do
    if m[4].hl_group then
      hls[m[2]] = m[4].hl_group
    end
    if m[4].virt_lines then
      virts = virts + 1
    end
  end
  eq(hls, { [1] = "DiagnosticOk", [2] = "Comment" })
  eq(virts, 2)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["prompt:set_placeholder"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  local p = prompt.new({ buf = buf })
  p:set_placeholder("Filter")
  local texts = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    table.insert(texts, m[4].virt_text[1][1])
  end
  eq(texts, { "❯ ", "Filter" })
  p:destroy()
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["config: MR keymaps, key lists, user_colors, on_inspect_mr"] = function()
  local c = config.get()
  eq({ c.keymaps.next_view, c.keymaps.prev_view, c.keymaps.inspect_mr }, { "<Tab>", "<S-Tab>", { "i", "<CR>" } })
  eq(type(c.on_inspect_mr), "function")
  eq(c.user_colors, {})
  eq({ config.setup({ keymaps = { inspect_mr = { "o" }, next_view = false }, user_colors = { ["user-1"] = "GitlabUser3" } }) }, { true, nil })
  c = config.get()
  eq({ c.keymaps.inspect_mr, c.keymaps.next_view, c.user_colors["user-1"] }, { { "o" }, false, "GitlabUser3" })
  local bad = {
    { { keymaps = { inspect_mr = {} } }, "ui.keymaps.inspect_mr" },
    { { keymaps = { inspect_mr = { "i", "" } } }, "ui.keymaps.inspect_mr" },
    { { user_colors = "x" }, "ui.user_colors" },
    { { user_colors = { ["user-1"] = 3 } }, "ui.user_colors.user-1" },
    { { on_inspect_mr = true }, "ui.on_inspect_mr" },
  }
  for _, case in ipairs(bad) do
    local ok, err = config.setup(case[1])
    eq(ok, false)
    eq(vim.startswith(err.message, case[2]), true)
  end
end

return T
