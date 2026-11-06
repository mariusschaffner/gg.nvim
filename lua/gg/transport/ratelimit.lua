--- Rate-limit handling and retry/backoff policy.
---
--- There is no shared limiter (that would be global mutable state): every
--- request decides on its own, from the response it got.
---
---   * 429 -> wait `Retry-After` (or `RateLimit-Reset` - now), capped by
---     `retry.max_retry_after_s`, for every method (the request was not processed).
---   * GET/HEAD also retry on 502/503/504 and network errors, with exponential
---     backoff and full jitter.
---   * At most `retry.max_attempts` attempts in total.
local task = require("gg.core.task")

local M = {}

M.RETRYABLE_STATUS = { [502] = true, [503] = true, [504] = true }
M.IDEMPOTENT = { GET = true, HEAD = true, OPTIONS = true }

---@class gg.RateLimit
---@field limit integer|nil RateLimit-Limit
---@field remaining integer|nil RateLimit-Remaining
---@field observed integer|nil RateLimit-Observed
---@field reset integer|nil RateLimit-Reset (Unix time)
---@field name string|nil RateLimit-Name

---@class gg.Clock
---@field now fun(): number current Unix time in seconds
---@field random fun(): number uniform in [0, 1)
---@field sleep fun(ms: integer): gg.Task

--- Parse the `RateLimit-*` headers (nil when there are none).
---@param headers table<string, string>|nil
---@return gg.RateLimit|nil
function M.parse(headers)
  if type(headers) ~= "table" then
    return nil
  end
  local rl = {
    limit = tonumber(headers["ratelimit-limit"]),
    remaining = tonumber(headers["ratelimit-remaining"]),
    observed = tonumber(headers["ratelimit-observed"]),
    reset = tonumber(headers["ratelimit-reset"]),
    name = headers["ratelimit-name"],
  }
  if rl.limit == nil and rl.remaining == nil and rl.reset == nil then
    return nil
  end
  return rl
end

--- Seconds the server asked us to wait, from Retry-After or RateLimit-Reset.
---@param headers table<string, string>|nil
---@param now number Unix time in seconds
---@return number|nil
function M.retry_after(headers, now)
  headers = headers or {}
  local ra = tonumber(headers["retry-after"])
  if ra and ra >= 0 then
    return ra
  end
  local reset = tonumber(headers["ratelimit-reset"])
  if reset then
    return math.max(0, reset - now)
  end
  return nil
end

--- Exponential backoff with full jitter, in milliseconds.
---@param attempt integer the attempt that just failed (1-based)
---@param retry gg.RetryConfig
---@param random fun(): number
---@return integer
function M.backoff(attempt, retry, random)
  local cap = math.min(retry.max_delay_ms, retry.base_delay_ms * 2 ^ (attempt - 1))
  return math.floor(random() * cap)
end

--- Decide whether to retry. Returns the delay in milliseconds, or nil.
---@param ctx { method: string, attempt: integer, retry: gg.RetryConfig, clock: gg.Clock, stream?: boolean }
---@param res gg.Response|nil the response, when one was received
---@param err gg.Error|nil the transport error, when none was received
---@return integer|nil delay_ms
---@return string|nil reason why not, when nil
function M.decide(ctx, res, err)
  if ctx.attempt >= ctx.retry.max_attempts then
    return nil, "attempts exhausted"
  end
  if res and res.status == 429 then
    local wait = M.retry_after(res.headers, ctx.clock.now())
    if wait == nil then
      return M.backoff(ctx.attempt, ctx.retry, ctx.clock.random), nil
    end
    if wait > ctx.retry.max_retry_after_s then
      return nil, "server asked to wait longer than retry.max_retry_after_s"
    end
    return math.floor(wait * 1000), nil
  end
  if not M.IDEMPOTENT[ctx.method] then
    return nil, "not idempotent"
  end
  if res and M.RETRYABLE_STATUS[res.status] then
    return M.backoff(ctx.attempt, ctx.retry, ctx.clock.random), nil
  end
  if err and err.kind == "network" and not ctx.stream then
    return M.backoff(ctx.attempt, ctx.retry, ctx.clock.random), nil
  end
  return nil, "not retryable"
end

--- A cancellable wait on a `vim.uv` timer.
---@param ms integer
---@return gg.Task
function M.sleep(ms)
  return task.new(function(resolve, _, on_cancel)
    local timer = vim.uv.new_timer()
    local function stop()
      if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end
    on_cancel(stop)
    timer:start(math.max(0, ms), 0, function()
      stop()
      vim.schedule(function()
        resolve(true)
      end)
    end)
  end)
end

--- The real clock.
---@return gg.Clock
function M.system_clock()
  return {
    now = os.time,
    random = math.random,
    sleep = M.sleep,
  }
end

return M
