--- Every change a detail view makes goes through `run`: a notice while it
--- runs, the request, then either the result applied (and the screens below
--- told that something changed) or the optimistic change rolled back and
--- the error shown; the view is redrawn either way.
local M = {}

---@class gg.ui.EditRun
---@field what string what changes, lower case: "title", "labels", …
---@field task fun(): gg.Task starts the request
---@field apply? fun(result: any) the request succeeded: take its result into the view
---@field rollback? fun(err: gg.Error) the request failed: undo an optimistic change
---@field render? fun() redraw (after apply / rollback)
---@field alive? fun(): boolean false once the view has closed (then nothing is applied)
---@field changed? fun() tell the screens below (e.g. `stack:changed("issue")`)
---@field done? fun(result: any, err: gg.Error|nil) after everything else
---@field busy? string the notice while running (default "Updating <what>…")
---@field success? string the notice afterwards (default "<What> updated"; false: none)

local function cap(s)
  return (s:gsub("^%l", string.upper))
end

--- The notices of a change: while running, after success, after failure.
---@param what string
---@return string busy
---@return string success
---@return fun(msg: string): string failure
function M.messages(what)
  return ("Updating %s…"):format(what), ("%s updated"):format(cap(what)), function(msg)
    return ("%s update failed: %s"):format(cap(what), msg)
  end
end

local function notify(msg, level)
  vim.notify("gg.ui: " .. msg, level or vim.log.levels.INFO)
end

--- Run a change.
---@param opts gg.ui.EditRun
---@return gg.Task
function M.run(opts)
  local busy, success, failure = M.messages(opts.what)
  notify(opts.busy or busy)
  local t = opts.task()
  t:on_done(function(result, err)
    if opts.alive and not opts.alive() then
      return
    end
    if err then
      if opts.rollback then
        opts.rollback(err)
      end
      notify(failure(err.message or tostring(err)), vim.log.levels.ERROR)
    else
      if opts.apply then
        opts.apply(result)
      end
      if opts.changed then
        opts.changed()
      end
      if opts.success ~= false then
        notify(opts.success or success)
      end
    end
    if opts.render then
      opts.render()
    end
    if opts.done then
      opts.done(result, err)
    end
  end)
  return t
end

--- A change that does not apply right now: say why instead of doing
--- nothing.
---@param msg string
function M.refuse(msg)
  notify(msg, vim.log.levels.WARN)
end

return M
