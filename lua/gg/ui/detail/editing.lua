--- The editing glue the detail views share: a text edited in place (a
--- description), a field edited in an overlay (a title, a sidebar value, a
--- date), completion sources loaded once per view, and cursor hints. Every
--- change goes through `gg.ui.detail.edit.run`.
local edit = require("gg.ui.detail.edit")
local field_edit = require("gg.ui.components.field_edit")
local text_edit = require("gg.ui.components.text_edit")

local M = {}

---@class gg.ui.TextEditing
---@field what string "description"
---@field load? fun(cb: fun(text: string|nil, err: gg.Error|nil)) fetch the current text first (else `text`)
---@field text? string
---@field cursor? integer line to start on
---@field save fun(text: string): gg.Task
---@field apply fun(result: any)
---@field changed? fun()
---@field render fun()

--- Edit a text in place in the host's content window.
---@param h gg.ui.DetailHost
---@param opts gg.ui.TextEditing
function M.text(h, opts)
  if h.editing then
    return edit.refuse("Finish the current edit first")
  end
  local function start(text)
    if h.closed or h.editing then
      return
    end
    h:begin_edit({ kind = "text" })
    text_edit.open({
      win = h.content_float.win,
      text = text,
      cursor = opts.cursor,
      keys = h.keys,
      on_save = function(new, done)
        if new == text then
          vim.notify(("gg.ui: %s unchanged"):format(opts.what:gsub("^%l", string.upper)), vim.log.levels.INFO)
          return done(true)
        end
        edit.run({
          what = opts.what,
          task = function()
            return opts.save(new)
          end,
          apply = opts.apply,
          changed = opts.changed,
          alive = function()
            return not h.closed
          end,
          done = function(_, err)
            done(err == nil)
          end,
        })
      end,
      on_close = function()
        h:end_edit()
        opts.render()
      end,
    })
  end
  if opts.load then
    opts.load(function(text, err)
      if err then
        return edit.refuse(("Cannot edit the %s: %s"):format(opts.what, err.message or tostring(err)))
      end
      start(text or "")
    end)
  else
    start(opts.text or "")
  end
end

---@class gg.ui.FieldEditing
---@field what string "labels"
---@field id? string the sidebar field drawn as being edited
---@field pane "header"|"content"|"sidebar"
---@field region string
---@field text string the current value as text
---@field multi? boolean
---@field complete? fun(query: string, cb: fun(items: gg.ui.Candidate[]))
---@field parse fun(text: string): any, string|nil the payload, or nil and why not
---@field unchanged? fun(text: string): boolean nothing to send
---@field save fun(payload: any): gg.Task
---@field apply fun(result: any)
---@field changed? fun()
---@field render fun()

--- Edit a field in an overlay laid over its region.
---@param h gg.ui.DetailHost
---@param opts gg.ui.FieldEditing
function M.field(h, opts)
  if h.editing then
    return edit.refuse("Finish the current edit first")
  end
  local pos = h:region_pos(opts.pane, opts.region)
  if not pos then
    return edit.refuse(("The %s field is not visible"):format(opts.what))
  end
  h:begin_edit({ kind = "field", id = opts.id })
  opts.render()
  return field_edit.open({
    row = pos.row,
    col = pos.col,
    width = pos.width,
    text = opts.text,
    multi = opts.multi,
    complete = opts.complete,
    keys = h.keys,
    group = h.group,
    on_save = function(text, done)
      if opts.unchanged and opts.unchanged(text) then
        vim.notify(("gg.ui: %s unchanged"):format(opts.what:gsub("^%l", string.upper)), vim.log.levels.INFO)
        return done(true)
      end
      local payload, why = opts.parse(text)
      if payload == nil then
        edit.refuse(why or ("Invalid %s"):format(opts.what))
        return done(false)
      end
      edit.run({
        what = opts.what,
        task = function()
          return opts.save(payload)
        end,
        apply = opts.apply,
        changed = opts.changed,
        alive = function()
          return not h.closed
        end,
        done = function(_, err)
          done(err == nil)
        end,
      })
    end,
    on_close = function()
      h:end_edit()
      opts.render()
    end,
  })
end

---@class gg.ui.Source
---@field get fun(self: gg.ui.Source, cb: fun(items: any[]|nil, err: gg.Error|nil))
---@field complete fun(query: string, cb: fun(items: gg.ui.Candidate[]))

--- A list loaded once (on first use) and reused, e.g. the project's labels.
--- `to_candidate` turns an item into a completion candidate.
---@param load fun(): gg.Task resolves with `{ items }` or a list
---@param to_candidate fun(item: any): gg.ui.Candidate
---@return gg.ui.Source
function M.source(load, to_candidate)
  local items, waiting, loading = nil, {}, false
  local src = {}
  function src.get(_, cb)
    if items then
      return cb(items)
    end
    table.insert(waiting, cb)
    if loading then
      return
    end
    loading = true
    load():on_done(function(res, err)
      loading = false
      if not err then
        items = res and res.items or res or {}
      end
      local w = waiting
      waiting = {}
      for _, f in ipairs(w) do
        f(items, err)
      end
    end)
  end
  function src.complete(_, cb)
    src:get(function(list)
      cb(vim.tbl_map(to_candidate, list or {}))
    end)
  end
  return src
end

--- Show `text(info)` right-aligned on the cursor line of tab `tab` (e.g.
--- "[x] toggle" on a task), redrawn as the cursor moves.
---@param h gg.ui.DetailHost
---@param tab string
---@param text fun(info: table|nil): gg.ui.Chunk[]|nil
function M.cursor_hint(h, tab, text)
  local buf = h:buf(tab)
  local ns = vim.api.nvim_create_namespace("gg.ui.detail.cursor_hint")
  local function draw()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    if h.closed or h.editing or h.active ~= tab then
      return
    end
    local info, lnum = h:current()
    local chunks = info and text(info)
    if chunks and lnum then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum - 1, 0, { virt_text = chunks, virt_text_pos = "right_align" })
    end
  end
  vim.api.nvim_create_autocmd("CursorMoved", { group = h.augroup, buffer = buf, callback = draw })
  return draw
end

return M
