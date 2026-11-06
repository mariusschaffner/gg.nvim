local H = require("tests.helpers")
local http = require("gg.transport.http")
local ratelimit = require("gg.transport.ratelimit")
local task = require("gg.core.task")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      H.reset()
    end,
  },
})

local RETRY = { max_attempts = 3, base_delay_ms = 100, max_delay_ms = 1000, max_retry_after_s = 60 }

-- A fake clock: time stands still, randomness is fixed, sleeps resolve at once
-- and are recorded.
local function fake_clock(now, rand)
  local clock = { slept = {} }
  clock.now = function()
    return now or 1000
  end
  clock.random = function()
    return rand or 0.5
  end
  clock.sleep = function(ms)
    table.insert(clock.slept, ms)
    return task.resolved(true)
  end
  return clock
end

local PATH = "/api/v4/projects/g%2Fr/issues"
local URL = "https://gitlab.example.com" .. PATH

local function run(responses, opts)
  local fake = H.fake(nil, { retry = RETRY })
  for _, r in ipairs(responses) do
    fake:add({ request = { path = PATH, method = (opts and opts.method) or "GET" }, response = r })
  end
  local clock = fake_clock(opts and opts.now, opts and opts.rand)
  local res, err = H.await(http.request(vim.tbl_extend("force", { host = H.TEST_HOST, url = URL, clock = clock }, opts and opts.request or {})))
  return res, err, clock, fake
end

T["parse RateLimit headers"] = function()
  eq(ratelimit.parse({ ["ratelimit-limit"] = "600", ["ratelimit-remaining"] = "599", ["ratelimit-reset"] = "1700000000", ["ratelimit-observed"] = "1", ["ratelimit-name"] = "throttle_authenticated_api" }), {
    limit = 600,
    remaining = 599,
    reset = 1700000000,
    observed = 1,
    name = "throttle_authenticated_api",
  })
  eq(ratelimit.parse({ ["content-type"] = "x" }), nil)
end

T["retry_after: Retry-After first, then RateLimit-Reset"] = function()
  eq(ratelimit.retry_after({ ["retry-after"] = "12" }, 0), 12)
  eq(ratelimit.retry_after({ ["ratelimit-reset"] = "1030" }, 1000), 30)
  eq(ratelimit.retry_after({ ["ratelimit-reset"] = "900" }, 1000), 0)
  eq(ratelimit.retry_after({}, 0), nil)
end

T["backoff: exponential with full jitter, capped"] = function()
  local half = function()
    return 0.5
  end
  eq(ratelimit.backoff(1, RETRY, half), 50)
  eq(ratelimit.backoff(2, RETRY, half), 100)
  eq(ratelimit.backoff(3, RETRY, half), 200)
  eq(ratelimit.backoff(10, RETRY, half), 500)
end

T["429 then 200: two requests, waiting Retry-After"] = function()
  local res, err, clock, fake = run({
    { status = 429, headers = { ["Retry-After"] = "3" }, body = "Retry later" },
    { status = 200, headers = { ["RateLimit-Remaining"] = "10", ["RateLimit-Limit"] = "600" }, body = "[]" },
  })
  eq(err, nil)
  eq(res.status, 200)
  eq(#fake:requests(), 2)
  eq(clock.slept, { 3000 })
  eq(res.rate_limit.remaining, 10)
end

T["429 on a POST is retried too (the request was not processed)"] = function()
  local res, _, clock = run({
    { status = 429, headers = { ["RateLimit-Reset"] = "1005" } },
    { status = 201, body = "{}" },
  }, { method = "POST", now = 1000, request = { method = "POST", body = "{}" } })
  eq(res.status, 201)
  eq(clock.slept, { 5000 })
end

T["a 503 on a POST is not retried"] = function()
  local _, err, clock, fake = run({ { status = 503 }, { status = 201 } }, { method = "POST", request = { method = "POST", body = "{}" } })
  eq(err.kind, "unknown")
  eq(err.status, 503)
  eq(#fake:requests(), 1)
  eq(clock.slept, {})
end

T["GET retries 502/503/504 with backoff"] = function()
  local res, _, clock = run({ { status = 502 }, { status = 504 }, { status = 200, body = "[]" } })
  eq(res.status, 200)
  eq(clock.slept, { 50, 100 })
end

T["GET retries network errors, not timeouts"] = function()
  local res, _, clock = run({ { error = { kind = "network" } }, { status = 200, body = "[]" } })
  eq(res.status, 200)
  eq(#clock.slept, 1)
  local _, err, clock2, fake = run({ { error = { kind = "timeout" } }, { status = 200 } })
  eq(err.kind, "timeout")
  eq(#fake:requests(), 1)
  eq(clock2.slept, {})
end

T["attempts run out: rate_limited with retry_after"] = function()
  local _, err, clock, fake = run({
    { status = 429, headers = { ["Retry-After"] = "1" } },
    { status = 429, headers = { ["Retry-After"] = "1" } },
    { status = 429, headers = { ["Retry-After"] = "2" } },
  })
  eq(err.kind, "rate_limited")
  eq(err.status, 429)
  eq(err.details.retry_after, 2)
  eq(err.details.attempts, 3)
  eq(#fake:requests(), 3)
  eq(clock.slept, { 1000, 1000 })
end

T["a Retry-After above the cap is not waited for"] = function()
  local _, err, clock = run({ { status = 429, headers = { ["Retry-After"] = "3600" } }, { status = 200 } })
  eq(err.kind, "rate_limited")
  eq(err.details.retry_after, 3600)
  eq(clock.slept, {})
end

T["other errors are not retried"] = function()
  local _, err, _, fake = run({ { status = 404, body = { message = "404 Not Found" } }, { status = 200 } })
  eq(err.kind, "not_found")
  eq(#fake:requests(), 1)
end

T["cancel during backoff sends no further request"] = function()
  local fake = H.fake(nil, { retry = RETRY })
  fake:add({ request = { path = PATH }, response = { status = 503 } })
  fake:add({ request = { path = PATH }, response = { status = 200 } })
  local slept = 0
  local clock = fake_clock()
  clock.sleep = function(ms)
    slept = slept + 1
    return ratelimit.sleep(ms * 10)
  end
  local t = http.request({ host = H.TEST_HOST, url = URL, clock = clock })
  H.wait_for(function()
    return slept == 1
  end)
  t:cancel()
  H.flush(200)
  eq(#fake:requests(), 1)
end

T["sleep waits on a timer and can be cancelled"] = function()
  local t0 = vim.uv.now()
  H.await(ratelimit.sleep(40))
  eq(vim.uv.now() - t0 >= 35, true)
  local s = ratelimit.sleep(10)
  local fired = false
  s:on_done(function()
    fired = true
  end)
  s:cancel()
  H.flush(50)
  eq(fired, false)
end

return T
