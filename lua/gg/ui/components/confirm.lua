--- Confirmations and the actions menu of the detail views, through
--- Neovim's own prompts (`vim.ui.input`, `vim.ui.select`), so a picker the
--- user configured for them is used.
local M = {}

--- Ask "<question> [y/N]: "; `on_yes` runs only for an answer starting
--- with y or Y, `on_no` for anything else (a dismissed prompt included).
---@param question string
---@param on_yes fun()
---@param on_no? fun()
function M.ask(question, on_yes, on_no)
  vim.ui.input({ prompt = question .. " [y/N]: " }, function(answer)
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
  vim.ui.select(items, {
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
