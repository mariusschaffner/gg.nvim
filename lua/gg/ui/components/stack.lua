--- A stack of screens: the picker at the bottom, detail views pushed on top.
---
--- Only the top screen is visible. `push` hides the current top (its
--- windows stay, with their buffers and state) and calls its `suspend`;
--- `pop` closes the top and brings the one below back with `resume`, so the
--- picker comes back with its selection, filter and tab untouched.
---
--- Closing a screen any other way (`:close`, focus leaving it) closes the
--- whole stack and returns to the window where it started.
---
--- A screen that changes something on GitLab calls `changed(kind)`; every
--- screen below it remembers the kind and gets `refresh(kinds)` when it is
--- on top again, so the tables show the new data after `q`.
local M = {}

---@class gg.ui.Screen
---@field group gg.ui.FloatGroup the screen's windows
---@field suspend? fun(self: gg.ui.Screen) covered by another screen: pause timers
---@field resume? fun(self: gg.ui.Screen) on top again
---@field teardown? fun(self: gg.ui.Screen) closed: cancel requests, stop timers
---@field refresh? fun(self: gg.ui.Screen, kinds: table<string, true>) on top again after a change above it
---@field dirty? table<string, true> kinds changed above this screen (set by the stack)

---@class gg.ui.Stack
---@field screens gg.ui.Screen[] bottom first
---@field private _popping gg.ui.Screen|nil
---@field private _closing boolean
---@field private _on_close fun()[]
local Stack = {}
Stack.__index = Stack

--- An empty stack.
---@return gg.ui.Stack
function M.new()
  return setmetatable({ screens = {}, _closing = false, _on_close = {} }, Stack)
end

local function call(screen, method)
  local fn = screen[method]
  if fn then
    local ok, err = pcall(fn, screen)
    if not ok then
      vim.notify(("gg.ui: %s: %s"):format(method, tostring(err)), vim.log.levels.ERROR)
    end
  end
end

--- The top screen, or nil.
---@return gg.ui.Screen|nil
function Stack:top()
  return self.screens[#self.screens]
end

--- The number of screens.
---@return integer
function Stack:depth()
  return #self.screens
end

--- Add the first screen (it is already open), or put `open(stack)`'s screen
--- on top: the current top is hidden and suspended first, so the new
--- windows can take the focus.
---@param open fun(stack: gg.ui.Stack): gg.ui.Screen
---@return gg.ui.Screen|nil
function Stack:push(open)
  if self._closing then
    return nil
  end
  local below = self:top()
  if below then
    below.group:hide()
    call(below, "suspend")
  end
  local ok, screen = pcall(open, self)
  if not ok or not screen then
    if below then
      below.group:show()
      call(below, "resume")
    end
    if not ok then
      vim.notify("gg.ui: " .. tostring(screen), vim.log.levels.ERROR)
    end
    return nil
  end
  self:adopt(screen)
  return screen
end

--- Track `screen` (already open) as the new top. `push` does this; the
--- first screen (the picker) is adopted directly.
---@param screen gg.ui.Screen
function Stack:adopt(screen)
  table.insert(self.screens, screen)
  screen.group:on_close(function()
    if self._popping == screen then
      return
    end
    -- closed from outside (`:close`, focus left): everything goes
    self:close()
  end)
end

--- Close the top screen and show the one below; closing the last one closes
--- the stack.
function Stack:pop()
  if self._closing then
    return
  end
  if #self.screens <= 1 then
    return self:close()
  end
  local top = table.remove(self.screens)
  self._popping = top
  top.group:close({ restore = false })
  self._popping = nil
  call(top, "teardown")
  local below = self:top()
  below.group:show()
  call(below, "resume")
  if below.dirty and next(below.dirty) and below.refresh then
    local kinds = below.dirty
    below.dirty = nil
    local ok, err = pcall(below.refresh, below, kinds)
    if not ok then
      vim.notify("gg.ui: refresh: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

--- Something of `kind` ("issue", "milestone", "merge_request",
--- "pipeline") changed on GitLab: every screen below the top refreshes when
--- it is shown again.
---@param kind string
function Stack:changed(kind)
  for i = 1, #self.screens - 1 do
    local s = self.screens[i]
    s.dirty = s.dirty or {}
    s.dirty[kind] = true
  end
end

--- Close every screen, top first; focus returns to the window that was
--- current before the first screen opened.
function Stack:close()
  if self._closing then
    return
  end
  self._closing = true
  while #self.screens > 0 do
    local s = table.remove(self.screens)
    self._popping = s
    s.group:close({ restore = #self.screens == 0 })
    call(s, "teardown")
  end
  self._popping = nil
  for _, fn in ipairs(self._on_close) do
    pcall(fn)
  end
end

--- Run `fn` once when the stack closes.
---@param fn fun()
function Stack:on_close(fn)
  table.insert(self._on_close, fn)
end

---@return boolean
function Stack:is_closed()
  return self._closing
end

return M
