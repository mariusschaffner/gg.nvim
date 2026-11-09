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

T["float_group: leaving to an outside window closes the group there"] = function()
  local outside = vim.api.nvim_get_current_win()
  local g = group_with_two()
  vim.api.nvim_set_current_win(outside)
  H.wait_for(function()
    return g:is_closed()
  end)
  eq(vim.api.nvim_get_current_win(), outside)
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

return T
