-- Helpers for the creation popup tests: a stack with a screen below, the
-- popup of a view on top, and readers for what its windows show.
local H = require("tests.helpers")
local X = require("tests.support.detail_data")
local config = require("gg.ui.config")
local create = require("gg.ui.create")
local date = require("gg.ui.lib.date")
local float_group = require("gg.ui.components.float_group")
local stack = require("gg.ui.components.stack")

local P = {}

P.notes = {}
local s
local saved = {}

function P.pre_case()
  saved = { columns = vim.o.columns, lines = vim.o.lines, notify = vim.notify, utc = date.utc_offset, select = vim.ui.select, input = vim.ui.input }
  vim.o.columns, vim.o.lines = 170, 50
  date.utc_offset = function()
    return 0
  end
  P.notes = {}
  vim.notify = function(msg, level)
    table.insert(P.notes, { msg, level })
  end
end

function P.post_case()
  vim.cmd("stopinsert")
  if s and not s:is_closed() then
    s:close()
  end
  s = nil
  vim.notify, vim.ui.select, vim.ui.input = saved.notify, saved.select, saved.input
  date.utc_offset = saved.utc
  vim.o.columns, vim.o.lines = saved.columns, saved.lines
  config.setup()
  H.reset()
end

--- A stack with one screen (stands in for the picker), and the context
--- views are opened with.
function P.stack(responses)
  local fake = H.fake()
  fake:add(responses or {})
  s = stack.new()
  local g = float_group.new({
    layout = function()
      return { base = { row = 0, col = 0, width = 20, height = 2 } }
    end,
  })
  g:add({ name = "base", enter = true })
  s:adopt({ group = g })
  return s, { stack = s, cfg = config.get(), host = X.HOST, project = X.PROJECT, today = X.TODAY }, fake
end

--- Open the popup of `kind` ("issue", "merge_request", "milestone",
--- "pipeline") over a base screen. Returns the popup, the stack and the
--- fake backend.
function P.open(kind, preset, responses)
  local st, ctx, fake = P.stack(responses)
  local popup = require("gg.ui.create.popup")
  local opened
  local real = popup.open
  popup.open = function(...)
    opened = real(...)
    return opened
  end
  local ok, err = pcall(create[kind], ctx, preset)
  popup.open = real
  assert(ok, err)
  assert(opened, "the popup did not open")
  return opened, st, fake
end

function P.keys(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "x", false)
end

function P.lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function flat(chunks)
  if type(chunks) ~= "table" then
    return chunks or ""
  end
  local out = {}
  for _, c in ipairs(chunks) do
    table.insert(out, c[1])
  end
  return table.concat(out)
end

function P.title(win)
  return flat(vim.api.nvim_win_get_config(win).title)
end

function P.footer(win)
  return flat(vim.api.nvim_win_get_config(win).footer)
end

--- The virtual texts of a buffer (first chunk of each), in order.
function P.virt(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    if m[4].virt_text then
      table.insert(out, m[4].virt_text[1][1])
    end
  end
  return out
end

--- The popup's diagnostic messages in a buffer.
function P.diagnostics(p, buf)
  return vim.tbl_map(function(d)
    return d.message
  end, vim.diagnostic.get(buf, { namespace = p.diag_ns }))
end

return P
