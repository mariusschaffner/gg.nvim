-- Left + right labels in one window border: the pure join, and the floats
-- that keep them right across resizes and focus changes.
local H = require("tests.helpers")
local border_label = require("gg.ui.lib.border_label")
local float = require("gg.ui.components.float")
local float_group = require("gg.ui.components.float_group")
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

local function flat(chunks)
  local out = {}
  for _, c in ipairs(chunks) do
    table.insert(out, c[1])
  end
  return table.concat(out)
end

T["join: fills the border exactly, measured in display cells"] = function()
  local chunks = border_label.join({ { " [i]", "K" }, { " Edit ", "D" } }, " Issue ", 30, "B")
  eq(chunks, {
    { " [i]", "K" },
    { " Edit ", "D" },
    { string.rep("─", 12), "B" },
    { " Issue " },
    { "─", "B" },
  })
  eq(vim.fn.strdisplaywidth(flat(chunks)), 30)
  -- wide and multi-byte glyphs count by cells, not bytes
  local wide = border_label.join(" ＋ New ⇄ ", " ⎇ x ", 40)
  eq(vim.fn.strdisplaywidth(flat(wide)), 40)
  eq(wide[2][2], "FloatBorder")
end

T["join: without a right label the left one is returned (cut to the width)"] = function()
  eq(border_label.join(" Title ", nil, 20), { { " Title " } })
  eq(border_label.join({ { " a long title ", "X" } }, nil, 6), { { " a lo…", "X" } })
  eq(border_label.join(nil, nil, 20), {})
end

T["join: the right label is dropped when both do not fit"] = function()
  eq(flat(border_label.join(" left label ", " right ", 19)), " left label ")
  eq(flat(border_label.join(" left label ", " right ", 21)), " left label ─ right ─")
  eq(border_label.width({ { "ab" }, { "＋" } }), 4)
end

local function title_of(win)
  return flat(vim.api.nvim_win_get_config(win).title)
end

T["float: title_right and footer_right are joined for the window's width"] = function()
  local f = float.open({
    rect = { row = 1, col = 1, width = 30, height = 2 },
    title = " Left ",
    title_right = " Right ",
    footer = " hints ",
    footer_right = " go ",
    label_hl = "NonText",
  })
  local cfg = vim.api.nvim_win_get_config(f.win)
  eq(flat(cfg.title), " Left " .. string.rep("─", 16) .. " Right ─")
  eq(flat(cfg.footer), " hints " .. string.rep("─", 18) .. " go ─")
  eq(cfg.title[2][2], "NonText")
  float.set_text(f.win, { footer = " x ", footer_right = " failed " })
  eq(flat(vim.api.nvim_win_get_config(f.win).footer), " x " .. string.rep("─", 18) .. " failed ─")
  -- a plain title still works as before
  float.set_text(f.win, { title = " Only " })
  eq(title_of(f.win), " Only ")
end

T["float_group: labels follow the width and the border colour"] = function()
  local width = 40
  local g = float_group.new({
    layout = function()
      return {
        a = { row = 0, col = 0, width = width, height = 1 },
        b = { row = 4, col = 0, width = width, height = 3 },
      }
    end,
  })
  g:add({ name = "a", title = " A " })
  g:add({ name = "b", enter = true, title = " [i] Edit ", title_right = " Issue ", footer = " hints ", footer_right = " create " })
  g:focus("b")
  local cfg = vim.api.nvim_win_get_config(g.members.b.win)
  eq(vim.fn.strdisplaywidth(flat(cfg.title)), 40)
  eq(cfg.title[2][2], "GitlabPickerBorderActive")
  g:focus("a")
  eq(vim.api.nvim_win_get_config(g.members.b.win).title[2][2], "GitlabPickerBorder")
  -- a plain title is left alone
  eq(title_of(g.members.a.win), " A ")
  width = 30
  g:relayout()
  cfg = vim.api.nvim_win_get_config(g.members.b.win)
  eq(flat(cfg.title), " [i] Edit " .. string.rep("─", 12) .. " Issue ─")
  eq(vim.fn.strdisplaywidth(flat(cfg.footer)), 30)
  g:set_labels("b", { footer_right = " creating… " })
  eq(flat(vim.api.nvim_win_get_config(g.members.b.win).footer), " hints " .. string.rep("─", 11) .. " creating… ─")
  g:set_labels("a", { title_right = " now " })
  eq(flat(vim.api.nvim_win_get_config(g.members.a.win).title), " A " .. string.rep("─", 21) .. " now ─")
  g:close()
  H.flush(5)
end

return T
