--- A queue of tasks that runs at most `concurrency` at a time. Jobs are
--- de-duplicated by key while queued or running. No vim.api.
local M = {}

---@class gg.ui.QueueJob
---@field key string
---@field start fun(): gg.Task
---@field done fun(result: any, err: gg.Error|nil)

---@class gg.ui.Queue
---@field concurrency integer
---@field running integer jobs started and not settled
---@field private _waiting gg.ui.QueueJob[]
---@field private _keys table<string, boolean> queued or running
---@field private _tasks table<string, gg.Task> running
local Queue = {}
Queue.__index = Queue

--- A new queue.
---@param opts? { concurrency?: integer } default 4
---@return gg.ui.Queue
function M.new(opts)
  return setmetatable({
    concurrency = math.max(1, (opts and opts.concurrency) or 4),
    running = 0,
    _waiting = {},
    _keys = {},
    _tasks = {},
  }, Queue)
end

--- Add a job. `start()` returns the task; `done` gets its result (never
--- called for a cancelled task). Returns false when `key` is already queued
--- or running.
---@param key string
---@param start fun(): gg.Task
---@param done fun(result: any, err: gg.Error|nil)
---@return boolean
function Queue:push(key, start, done)
  if self._keys[key] then
    return false
  end
  self._keys[key] = true
  table.insert(self._waiting, { key = key, start = start, done = done })
  self:_pump()
  return true
end

---@private
function Queue:_pump()
  while self.running < self.concurrency and #self._waiting > 0 do
    local job = table.remove(self._waiting, 1)
    self.running = self.running + 1
    local t = job.start()
    self._tasks[job.key] = t
    t:on_done(function(result, err)
      self.running = self.running - 1
      self._tasks[job.key] = nil
      self._keys[job.key] = nil
      job.done(result, err)
      self:_pump()
    end)
  end
end

--- Jobs waiting to start.
---@return integer
function Queue:waiting()
  return #self._waiting
end

--- True when `key` is queued or running.
---@param key string
---@return boolean
function Queue:has(key)
  return self._keys[key] == true
end

--- Drop the jobs that have not started; running ones finish normally.
function Queue:clear()
  for _, job in ipairs(self._waiting) do
    self._keys[job.key] = nil
  end
  self._waiting = {}
end

--- Drop the waiting jobs and cancel the running ones.
function Queue:cancel_all()
  self:clear()
  for key, t in pairs(self._tasks) do
    t:cancel()
    self._tasks[key] = nil
    self._keys[key] = nil
  end
  self.running = 0
end

return M
