--- Prompts, confirmations and the actions menu of the views.
---
--- A choice (`select`, `menu`) is made in the views' own filtered list
--- (`gg.ui.components.select`), centred in the editor; only an editor too
--- small for it falls back to `vim.ui.select`. Text and yes/no questions go
--- through `vim.ui.input`, so an input the user configured is used.
---
--- Such a prompt may draw its own window and take the focus; the screen that
--- asked is held open meanwhile (`float_group.hold`) and gets the focus back
--- before the answer is handled. Views always prompt through this module,
--- never through `vim.ui` directly.
local chooser = require("gg.ui.components.select")
local float_group = require("gg.ui.components.float_group")

local M = {}

-- `cb` once, after the screen that asked has the focus again
local function answered(cb)
  local release = float_group.hold()
  local done = false
  return function(...)
    if done then
      return
    end
    done = true
    release()
    cb(...)
  end
end

--- Let the user choose one of `items` in a filtered list; `on_choice` gets
--- the item and its index, or nil when the list was dismissed.
---@generic T
---@param items T[]
---@param opts { prompt?: string, format_item?: fun(item: T): string }
---@param on_choice fun(item: T|nil, idx: integer|nil)
function M.select(items, opts, on_choice)
  local cb = answered(on_choice)
  local text = opts.format_item or tostring
  local at = chooser.centered(#items)
  chooser.open({
    title = opts.prompt or "Select",
    row = at.row,
    col = at.col,
    width = at.width,
    fit = true,
    load = chooser.static(items, text),
    text = text,
    line = function(item)
      return " " .. text(item)
    end,
    on_pick = function(item)
      for i, it in ipairs(items) do
        if rawequal(it, item) then
          return cb(item, i)
        end
      end
      cb(item)
    end,
    on_close = function(picked)
      if not picked then
        cb(nil)
      end
    end,
  })
end

--- `vim.ui.input` for a view.
---@param opts { prompt?: string, default?: string }
---@param on_confirm fun(text: string|nil)
function M.input(opts, on_confirm)
  vim.ui.input(opts, answered(on_confirm))
end

--- Ask "<question> [y/N]: "; `on_yes` runs only for an answer starting
--- with y or Y, `on_no` for anything else (a dismissed prompt included).
---@param question string
---@param on_yes fun()
---@param on_no? fun()
function M.ask(question, on_yes, on_no)
  M.input({ prompt = question .. " [y/N]: " }, function(answer)
    if answer and answer:match("^%s*[yY]") then
      on_yes()
    elseif on_no then
      on_no()
    end
  end)
end

---@class gg.ui.MenuItem
---@field label string
---@field run fun()
---@field confirm? string ask this first ("Close !12?")

--- Let the user pick one of `items` and run it (after its confirmation).
--- Nothing to pick: says so.
---@param title string
---@param items gg.ui.MenuItem[]
function M.menu(title, items)
  if #items == 0 then
    vim.notify("gg.ui: no actions available", vim.log.levels.INFO)
    return
  end
  M.select(items, {
    prompt = title,
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    if not item then
      return
    end
    if item.confirm then
      M.ask(item.confirm, item.run)
    else
      item.run()
    end
  end)
end

return M
