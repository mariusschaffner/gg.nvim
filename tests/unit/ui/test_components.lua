-- gg.ui.components: layout, float group, prompt, list buffer (real windows, headless).
local H = require("tests.helpers")
local float_group = require("gg.ui.components.float_group")
local layout = require("gg.ui.components.layout")
local list_buffer = require("gg.ui.components.list_buffer")
local prompt = require("gg.ui.components.prompt")
local tabs = require("gg.ui.components.tabs")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      vim.cmd("silent! only!")
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= "" then
          pcall(vim.api.nvim_win_close, w, true)
        end
      end
    end,
  },
})

T["layout.stack: fixed + fill, borders and gap"] = function()
  local r = layout.stack({ { height = 1 }, { fill = true } }, { gap = 1, area = { columns = 100, lines = 40 } })
  eq(r, {
    { row = 0, col = 0, width = 98, height = 1 },
    { row = 4, col = 0, width = 98, height = 34 },
  })
  eq(r[2].row + r[2].height + 2, 40) -- fills the area exactly
end

T["tabs.segments"] = function()
  eq(tabs.segments({ { key = "a", label = "Open", count = 9 }, { key = "b", label = "All" } }, "a"), {
    { " Open 9 ", "GitlabTabActive" },
    { " ", nil },
    { " All … ", "GitlabTab" },
  })
  eq(tabs.segments({ { key = "a", label = "Open", count = 9 } }, "a", { pad = 2 }), { { "  Open 9  ", "GitlabTabActive" } })
end

local function group_with_two()
  local g = float_group.new({
    layout = function()
      local r = layout.stack({ { height = 1 }, { fill = true } })
      return { a = r[1], b = r[2] }
    end,
  })
  g:add({ name = "a", title = " A " })
  g:add({ name = "b", enter = true })
  return g
end

T["float_group: closing one member closes all and restores the previous window"] = function()
  local prev = vim.api.nvim_get_current_win()
  local g = group_with_two()
  local closed = 0
  g:on_close(function()
    closed = closed + 1
  end)
  eq(vim.api.nvim_get_current_win(), g.members.b.win)
  vim.api.nvim_win_close(g.members.a.win, true)
  H.wait_for(function()
    return g:is_closed()
  end)
  eq(vim.api.nvim_win_is_valid(g.members.b.win), false)
  eq(vim.api.nvim_get_current_win(), prev)
  eq(closed, 1)
  g:close() -- idempotent
  eq(closed, 1)
end

T["float_group: focus paints the active border, resize relayouts"] = function()
  local g = group_with_two()
  g:focus("a")
  eq(vim.wo[g.members.a.win].winhighlight:find("FloatBorder:GitlabPickerBorderActive", 1, true) ~= nil, true)
  eq(vim.wo[g.members.b.win].winhighlight:find("FloatBorder:GitlabPickerBorder,", 1, true) ~= nil, true)
  local resized = 0
  g:on_resize(function()
    resized = resized + 1
  end)
  local cols = vim.o.columns
  vim.o.columns = cols - 10 -- fires VimResized
  H.flush(20)
  eq(resized >= 1, true)
  eq(vim.api.nvim_win_get_width(g.members.b.win), cols - 12)
  vim.o.columns = cols
  g:close()
end

T["float_group: a member can have its own border groups"] = function()
  local g = float_group.new({
    layout = function()
      local r = layout.stack({ { height = 1 }, { fill = true } })
      return { a = r[1], b = r[2] }
    end,
  })
  g:add({ name = "a" })
  g:add({ name = "b", enter = true, border_hl = "GrayBorder", border_active_hl = "GrayBorder" })
  g:focus("b")
  eq(vim.wo[g.members.b.win].winhighlight:find("FloatBorder:GrayBorder,", 1, true) ~= nil, true)
  g:focus("a")
  eq(vim.wo[g.members.a.win].winhighlight:find("FloatBorder:GitlabPickerBorderActive", 1, true) ~= nil, true)
  eq(vim.wo[g.members.b.win].winhighlight:find("FloatBorder:GrayBorder,", 1, true) ~= nil, true)
  g:close()
end

T["float_group: leaving to an outside window closes the group there"] = function()
  local outside = vim.api.nvim_get_current_win()
  local g = group_with_two()
  vim.api.nvim_set_current_win(outside)
  H.wait_for(function()
    return g:is_closed()
  end)
  eq(vim.api.nvim_get_current_win(), outside)
end

T["float_group: held while a prompt in its own window has the focus"] = function()
  local outside = vim.api.nvim_get_current_win()
  local g = group_with_two()
  g:focus("a")
  local release = float_group.hold()
  -- a picker: its own float takes the focus, then it closes and leaves the
  -- focus in a window outside the group
  local pick = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, { relative = "editor", row = 1, col = 1, width = 10, height = 1 })
  H.flush(20)
  eq(g:is_closed(), false)
  vim.api.nvim_win_close(pick, true)
  vim.api.nvim_set_current_win(outside)
  H.flush(20)
  eq(g:is_closed(), false)
  release()
  eq(vim.api.nvim_get_current_win(), g.members.a.win)
  release() -- idempotent
  H.flush(20)
  eq(g:is_closed(), false)
  -- not held any more: leaving closes it again
  vim.api.nvim_set_current_win(outside)
  H.wait_for(function()
    return g:is_closed()
  end)
  -- no group has the focus: nothing to hold
  float_group.hold()()
end

local function list_fixture()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  local selected = {}
  local l = list_buffer.new({
    buf = buf,
    win = vim.api.nvim_get_current_win(),
    on_select = function(lnum)
      table.insert(selected, lnum)
    end,
  })
  l:set({
    lines = { "header", "one", "filler", "two", "three", "filler" },
    marks = { { row = 0, col = 0, end_col = 6, hl = "Title" } },
    virt_lines = { { row = 1, chunks = { { "──", "Comment" } } } },
    selectable = { 2, 4, 5 },
  })
  l:attach_navigation()
  return l, buf, selected
end

T["list_buffer: content, read-only, extmarks"] = function()
  local l, buf = list_fixture()
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[4], "two")
  eq(vim.bo[buf].modifiable, false)
  local marks = vim.api.nvim_buf_get_extmarks(buf, l.ns, 0, -1, { details = true })
  eq(#marks, 2)
end

T["list_buffer: navigation skips non-selectable lines and clamps"] = function()
  local l, _, selected = list_fixture()
  l:select(1)
  eq(l:current(), 2)
  l:move(1)
  eq(l:current(), 4)
  l:move(5)
  eq(l:current(), 5)
  l:move(-10)
  eq(l:current(), 2)
  eq(l:nearest(3), 2)
  eq(l:nearest(3, 1), 4)
  eq(l:nearest(6, 1), 5)
  eq(selected[#selected], 2)
  -- keymaps
  vim.api.nvim_feedkeys("j", "x", false)
  eq(l:current(), 4)
  vim.api.nvim_feedkeys("G", "x", false)
  eq(l:current(), 5)
  vim.api.nvim_feedkeys("gg", "x", false)
  eq(l:current(), 2)
  -- CursorMoved snaps a free cursor back onto a selectable line, in the moving direction
  vim.api.nvim_win_set_cursor(0, { 3, 2 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
  eq(vim.api.nvim_win_get_cursor(0), { 4, 0 })
end

T["prompt: debounced on_change, placeholder, counter, single line"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  local got = {}
  local p = prompt.new({
    buf = buf,
    debounce_ms = 10,
    on_change = function(s)
      table.insert(got, s)
    end,
  })
  local function virt()
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
      if m[4].virt_text then
        table.insert(out, m[4].virt_text[1][1])
      end
    end
    return out
  end
  eq(virt(), { "❯ ", "filter" })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "~bu" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "~bug" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  H.wait_for(function()
    return #got > 0
  end)
  H.flush(30)
  eq(got, { "~bug" }) -- debounced: one call with the last text
  eq(virt(), { "❯ " })
  p:set_counter("1 / 9")
  eq(virt(), { "❯ ", "1 / 9" })
  p:set_text("")
  eq(got[#got], "")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "a b" })
  p:destroy()
end

T["select: static filter, ticking several, the cursor on the current one"] = function()
  local chooser = require("gg.ui.components.select")
  local words = { "alpha", "beta", "alphabet", "gamma" }
  local function id(w)
    return w
  end
  local load = chooser.static(words, id)
  local got
  load("", function(items)
    got = items
  end)
  eq(got, words)
  load("PH", function(items)
    got = items
  end)
  eq(got, { "alpha", "alphabet" })
  load("bet", function(items)
    got = items
  end)
  eq(got, { "beta", "alphabet" }) -- what starts with it first
  eq(chooser.centered(3, 40), { row = math.floor((vim.o.lines - vim.o.cmdheight - 8) / 2), col = math.floor((vim.o.columns - 40) / 2), width = 40 })

  local function line(w)
    return " " .. w
  end
  local function buf_lines(pk)
    return vim.api.nvim_buf_get_lines(pk.list_float.buf, 0, -1, false)
  end
  -- several: ticked in order, kept while the filter hides them
  local picked, closed
  local pk = chooser.open({
    title = "Words",
    row = 1,
    col = 2,
    width = 40,
    multi = true,
    fit = true,
    debounce_ms = 0,
    selected = { "gamma" },
    load = load,
    line = line,
    key = id,
    on_pick = function(items)
      picked = items
    end,
    on_close = function(p)
      closed = p
    end,
  })
  eq(buf_lines(pk), { "   alpha", "   beta", "   alphabet", " ✓ gamma" })
  eq(vim.api.nvim_win_get_height(pk.list_float.win), 4)
  pk:toggle() -- alpha, and on to beta
  eq(pk.index, 2)
  vim.api.nvim_buf_set_lines(pk.prompt_float.buf, 0, -1, false, { "bet" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = pk.prompt_float.buf })
  eq(buf_lines(pk), { "   beta", "   alphabet" })
  eq(vim.api.nvim_win_get_height(pk.list_float.win), 2) -- fits the matches
  pk:toggle()
  eq(pk:selection(), { "gamma", "alpha", "beta" })
  pk:move(-1)
  pk:toggle() -- beta again: unticked
  pk:pick()
  eq({ picked, closed, pk.closed }, { { "gamma", "alpha" }, true, true })
  eq(vim.api.nvim_win_is_valid(pk.prompt_float.win), false)

  -- one: the cursor starts on the current value, the list keeps its height
  pk = chooser.open({
    title = "Word",
    row = 1,
    col = 2,
    width = 40,
    current = "alphabet",
    load = load,
    line = line,
    key = id,
    on_pick = function(item)
      picked = item
    end,
  })
  eq(pk.index, 3)
  eq(vim.api.nvim_win_get_height(pk.list_float.win), chooser.MAX_ROWS)
  pk:toggle() -- nothing to tick
  pk:pick()
  eq(picked, "alphabet")

  -- no room: a single choice asks vim.ui.select, several are refused
  local saved = { select = vim.ui.select, notify = vim.notify }
  local note
  vim.notify = function(msg)
    note = msg
  end
  closed = nil
  eq(chooser.open({ title = "Words", row = vim.o.lines - 2, col = 0, width = 40, multi = true, load = load, line = line, on_pick = id, on_close = function(p)
    closed = p
  end }), nil)
  vim.ui.select, vim.notify = saved.select, saved.notify
  eq({ note, closed }, { "gg.ui: No room to choose: Words", false })
end

T["select: <CR> after typing takes the match under the cursor (multi)"] = function()
  local chooser = require("gg.ui.components.select")
  local words = { "alpha", "beta", "alphabet", "gamma" }
  local function id(w)
    return w
  end
  local picked
  local function open(debounce)
    picked = nil
    return chooser.open({
      title = "Words",
      row = 1,
      col = 2,
      width = 40,
      multi = true,
      debounce_ms = debounce,
      selected = { "gamma" },
      load = chooser.static(words, id),
      line = function(w)
        return " " .. w
      end,
      key = id,
      on_pick = function(items)
        picked = items
      end,
    })
  end
  local function type_in(pk, s, fire)
    vim.api.nvim_buf_set_lines(pk.prompt_float.buf, 0, -1, false, { s })
    if fire then
      vim.api.nvim_exec_autocmds("TextChangedI", { buffer = pk.prompt_float.buf })
    end
  end
  -- typed, no <Tab>: the match under the cursor joins what is ticked
  local pk = open(0)
  type_in(pk, "bet", true)
  pk:pick()
  eq(picked, { "gamma", "beta" })
  -- a <Tab> after typing: only what is ticked
  pk = open(0)
  type_in(pk, "bet", true)
  pk:toggle() -- beta, the cursor moves on to alphabet
  pk:pick()
  eq(picked, { "gamma", "beta" })
  -- an item that is ticked already stays ticked
  pk = open(0)
  type_in(pk, "gam", true)
  pk:pick()
  eq(picked, { "gamma" })
  -- no filter: just what is ticked
  pk = open(0)
  pk:pick()
  eq(picked, { "gamma" })
  -- <CR> before the debounced filter ran: it waits for the matches
  pk = open(10000)
  type_in(pk, "alphab", false)
  pk:pick()
  eq(picked, { "gamma", "alphabet" })
  eq(pk.closed, true)
end

return T
