--- Async tasks with cancellation.
---
--- Every request in gg returns a `gg.Task`. A task can be:
---   * used with a callback:   `t:on_done(function(result, err) ... end)`
---   * awaited in a coroutine: `local result, err = t:await()` (see `task.run`)
---   * cancelled:              `t:cancel()`
---
--- Rules:
---   * A task settles exactly once: resolved (result) or rejected (err).
---   * Callbacks always run through `vim.schedule`, never synchronously, even
---     when the task has already settled.
---   * A cancelled task never calls its callbacks. Its producer's cancel hooks
---     run once (that is where a request kills its process).
---   * Cancelling a `task.run` cancels the child task it is awaiting, and its
---     coroutine is never resumed.
---   * A coroutine awaiting a task that is cancelled from outside is resumed
---     with `nil, err` where `errors.is_cancelled(err)`.
---
--- `owners` maps a running coroutine to the `task.run` task driving it. It is
--- weak-keyed bookkeeping for structured cancellation, not shared state.
local errors = require("gg.core.errors")

local M = {}

---@alias gg.TaskState "pending"|"resolved"|"rejected"|"cancelled"

---@class gg.Task
---@field private _state gg.TaskState
---@field private _result any
---@field private _err gg.Error|nil
---@field private _callbacks fun(result: any, err: gg.Error|nil)[]
---@field private _subscribers fun(state: gg.TaskState, result: any, err: gg.Error|nil)[]
---@field private _cancel_hooks fun()[]
---@field private _current gg.Task|nil child awaited by a task.run coroutine
local Task = {}
Task.__index = Task

local owners = setmetatable({}, { __mode = "k" })

local function new_task()
  return setmetatable({
    _state = "pending",
    _callbacks = {},
    _subscribers = {},
    _cancel_hooks = {},
  }, Task)
end

local function notify(self)
  local state, result, err = self._state, self._result, self._err
  if state ~= "cancelled" then
    for _, cb in ipairs(self._callbacks) do
      vim.schedule(function()
        cb(result, err)
      end)
    end
  end
  for _, sub in ipairs(self._subscribers) do
    sub(state, result, err)
  end
  self._callbacks = {}
  self._subscribers = {}
end

---@private
---@param value any
function Task:_resolve(value)
  if self._state ~= "pending" then
    return
  end
  self._state = "resolved"
  self._result = value
  notify(self)
end

---@private
---@param err any
function Task:_reject(err)
  if self._state ~= "pending" then
    return
  end
  self._state = "rejected"
  self._err = errors.wrap(err)
  notify(self)
end

--- Internal: called synchronously when the task leaves "pending" (including on cancel).
---@private
---@param fn fun(state: gg.TaskState, result: any, err: gg.Error|nil)
function Task:_subscribe(fn)
  if self._state == "pending" then
    table.insert(self._subscribers, fn)
  else
    fn(self._state, self._result, self._err)
  end
end

--- Register a callback for when the task settles. It runs via `vim.schedule`,
--- exactly once, and never if the task is cancelled.
---@param cb fun(result: any, err: gg.Error|nil)
---@return gg.Task self
function Task:on_done(cb)
  if self._state == "pending" then
    table.insert(self._callbacks, cb)
  elseif self._state ~= "cancelled" then
    local result, err = self._result, self._err
    vim.schedule(function()
      cb(result, err)
    end)
  end
  return self
end

--- Cancel the task. Idempotent; a settled task is not affected.
function Task:cancel()
  if self._state ~= "pending" then
    return
  end
  self._state = "cancelled"
  local hooks = self._cancel_hooks
  self._cancel_hooks = {}
  for _, hook in ipairs(hooks) do
    pcall(hook)
  end
  notify(self)
end

--- Wait for the task inside a coroutine. Outside a coroutine it returns a
--- validation error instead of blocking.
---@return any result
---@return gg.Error|nil err
function Task:await()
  local co, is_main = coroutine.running()
  if not co or is_main then
    return nil, errors.new("validation", "Task:await() must be called inside a coroutine (use gg.task.run)")
  end
  if self._state == "resolved" then
    return self._result, nil
  elseif self._state == "rejected" then
    return nil, self._err
  elseif self._state == "cancelled" then
    return nil, errors.cancelled()
  end

  local owner = owners[co]
  if owner then
    owner._current = self
  end
  self:_subscribe(function(state, result, err)
    vim.schedule(function()
      if owner and owner._state == "cancelled" then
        return
      end
      if coroutine.status(co) ~= "suspended" then
        return
      end
      local ok, msg
      if state == "cancelled" then
        ok, msg = coroutine.resume(co, nil, errors.cancelled())
      else
        ok, msg = coroutine.resume(co, result, err)
      end
      if not ok then
        error(msg, 0)
      end
    end)
  end)
  local result, err = coroutine.yield()
  if owner and owner._current == self then
    owner._current = nil
  end
  return result, err
end

---@return boolean
function Task:is_done()
  return self._state ~= "pending"
end

---@return boolean
function Task:is_cancelled()
  return self._state == "cancelled"
end

--- Create a task from a producer. The producer runs synchronously and starts
--- the work; it must call `resolve` or `reject` later (or immediately).
--- A Lua error in the producer rejects the task with kind "unknown".
---@param producer fun(resolve: fun(value: any), reject: fun(err: any), on_cancel: fun(hook: fun()))
---@return gg.Task
function M.new(producer)
  local t = new_task()
  local function resolve(v)
    t:_resolve(v)
  end
  local function reject(e)
    t:_reject(e)
  end
  local function on_cancel(hook)
    if t._state == "cancelled" then
      pcall(hook)
    elseif t._state == "pending" then
      table.insert(t._cancel_hooks, hook)
    end
  end
  local ok, msg = pcall(producer, resolve, reject, on_cancel)
  if not ok then
    t:_reject(errors.new("unknown", "task producer failed: " .. tostring(msg)))
  end
  return t
end

--- Run `fn` in a coroutine. `fn` may `:await()` other tasks. Its return value
--- `(result, err)` settles the task: a non-nil `err` rejects it. A Lua error
--- inside `fn` rejects with kind "unknown"; nothing is thrown.
---@param fn fun(...): any, gg.Error|nil
---@param ... any arguments passed to fn
---@return gg.Task
function M.run(fn, ...)
  local t = new_task()
  local args = { n = select("#", ...), ... }
  local co = coroutine.create(function()
    local ok, result, err = xpcall(function()
      return fn(unpack(args, 1, args.n))
    end, debug.traceback)
    if not ok then
      t:_reject(errors.new("unknown", "task function failed: " .. tostring(result)))
    elseif err ~= nil then
      t:_reject(err)
    else
      t:_resolve(result)
    end
  end)
  owners[co] = t
  table.insert(t._cancel_hooks, function()
    local child = t._current
    t._current = nil
    if child then
      child:cancel()
    end
  end)
  local ok, msg = coroutine.resume(co)
  if not ok then
    t:_reject(errors.new("unknown", "task function failed: " .. tostring(msg)))
  end
  return t
end

--- A task that is already resolved with `value`.
---@param value any
---@return gg.Task
function M.resolved(value)
  local t = new_task()
  t:_resolve(value)
  return t
end

--- A task that is already rejected with `err`.
---@param err gg.Error|any
---@return gg.Task
function M.failed(err)
  local t = new_task()
  t:_reject(err)
  return t
end

--- Wait for all tasks. Resolves with their results in order. The first error
--- (or an external cancel of a child) rejects it and cancels the rest.
--- Cancelling it cancels every child.
---@param tasks gg.Task[]
---@return gg.Task
function M.all(tasks)
  return M.new(function(resolve, reject, on_cancel)
    local n = #tasks
    local results = { n = n }
    local remaining = n
    if n == 0 then
      resolve(results)
      return
    end
    local finished = false
    local function cancel_others(except)
      for _, other in ipairs(tasks) do
        if other ~= except then
          other:cancel()
        end
      end
    end
    on_cancel(function()
      finished = true
      cancel_others(nil)
    end)
    for i, child in ipairs(tasks) do
      child:_subscribe(function(state, result, err)
        if finished then
          return
        end
        if state == "resolved" then
          results[i] = result
          remaining = remaining - 1
          if remaining == 0 then
            finished = true
            resolve(results)
          end
        else
          finished = true
          cancel_others(child)
          reject(state == "cancelled" and errors.cancelled() or err)
        end
      end)
    end
  end)
end

--- True when `v` is a gg.Task.
---@param v any
---@return boolean
function M.is_task(v)
  return getmetatable(v) == Task
end

return M
