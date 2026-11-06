local H = require("tests.helpers")
local task = require("gg.core.task")
local errors = require("gg.core.errors")
local eq = MiniTest.expect.equality

local T = MiniTest.new_set()

-- A task that settles only when the test says so.
local function deferred()
  local ctl = { cancelled = 0 }
  ctl.task = task.new(function(resolve, reject, on_cancel)
    ctl.resolve, ctl.reject = resolve, reject
    on_cancel(function()
      ctl.cancelled = ctl.cancelled + 1
    end)
  end)
  return ctl
end

T["settles exactly once"] = function()
  local d = deferred()
  local calls = {}
  d.task:on_done(function(r, e)
    table.insert(calls, { r, e })
  end)
  d.resolve(1)
  d.resolve(2)
  d.reject(errors.new("network", "late"))
  H.flush()
  eq(calls, { { 1, nil } })
end

T["callbacks are scheduled, never synchronous"] = function()
  local d = deferred()
  local called = false
  d.task:on_done(function()
    called = true
  end)
  d.resolve("x")
  eq(called, false)
  H.flush()
  eq(called, true)

  -- also when registering on an already settled task
  local late = false
  task.resolved(1):on_done(function()
    late = true
  end)
  eq(late, false)
  H.flush()
  eq(late, true)
end

T["rejects with a gg error"] = function()
  local _, err = H.await(task.failed(errors.new("not_found", "nope", { status = 404 })))
  eq(err.kind, "not_found")
  eq(err.status, 404)
  local _, wrapped = H.await(task.failed("plain string"))
  eq(wrapped.kind, "unknown")
  eq(wrapped.message, "plain string")
end

T["cancel is idempotent, runs hooks once and suppresses callbacks"] = function()
  local d = deferred()
  local called = false
  d.task:on_done(function()
    called = true
  end)
  d.task:cancel()
  d.task:cancel()
  d.resolve(1)
  H.flush()
  eq(d.cancelled, 1)
  eq(called, false)
  eq(d.task:is_cancelled(), true)
  eq(d.task:is_done(), true)
  -- registering after the cancel never fires either
  d.task:on_done(function()
    called = true
  end)
  H.flush()
  eq(called, false)
end

T["cancel after settle does nothing"] = function()
  local d = deferred()
  d.resolve(1)
  d.task:cancel()
  eq(d.cancelled, 0)
  eq(d.task:is_cancelled(), false)
end

T["producer errors reject with kind unknown"] = function()
  local t = task.new(function()
    error("boom")
  end)
  local _, err = H.await(t)
  eq(err.kind, "unknown")
  eq(err.message:find("boom", 1, true) ~= nil, true)
end

T["await outside a coroutine returns a validation error"] = function()
  local r, err = task.resolved(1):await()
  eq(r, nil)
  eq(err.kind, "validation")
end

T["run awaits children and returns their results"] = function()
  local a, b = deferred(), deferred()
  local t = task.run(function()
    local x = a.task:await()
    local y = b.task:await()
    return x + y
  end)
  a.resolve(2)
  H.flush()
  b.resolve(3)
  eq(H.await(t), 5)
end

T["run turns (nil, err) into a rejection"] = function()
  local t = task.run(function()
    local _, err = task.failed(errors.new("forbidden", "no")):await()
    return nil, err
  end)
  local _, err = H.await(t)
  eq(err.kind, "forbidden")
end

T["a Lua error inside run becomes kind unknown"] = function()
  local t = task.run(function()
    error("kaput")
  end)
  local _, err = H.await(t)
  eq(err.kind, "unknown")
  eq(err.message:find("kaput", 1, true) ~= nil, true)
end

T["cancelling run cancels the awaited child and never resumes"] = function()
  local d = deferred()
  local resumed = false
  local t = task.run(function()
    d.task:await()
    resumed = true
  end)
  t:cancel()
  H.flush()
  eq(d.cancelled, 1)
  eq(d.task:is_cancelled(), true)
  eq(resumed, false)
end

T["an awaited child cancelled from outside resumes with a cancelled error"] = function()
  local d = deferred()
  local t = task.run(function()
    local _, err = d.task:await()
    return { cancelled = errors.is_cancelled(err) }
  end)
  d.task:cancel()
  eq(H.await(t), { cancelled = true })
end

T["all keeps order"] = function()
  local a, b = deferred(), deferred()
  local t = task.all({ a.task, b.task })
  b.resolve("b")
  a.resolve("a")
  local res = H.await(t)
  eq({ res[1], res[2] }, { "a", "b" })
end

T["all fails on the first error and cancels the rest"] = function()
  local a, b = deferred(), deferred()
  local t = task.all({ a.task, b.task })
  a.reject(errors.new("timeout", "slow"))
  local _, err = H.await(t)
  eq(err.kind, "timeout")
  eq(b.cancelled, 1)
end

T["cancelling all cancels every child"] = function()
  local a, b = deferred(), deferred()
  local t = task.all({ a.task, b.task })
  t:cancel()
  eq({ a.cancelled, b.cancelled }, { 1, 1 })
end

T["all of nothing resolves empty"] = function()
  local res = H.await(task.all({}))
  eq(res.n, 0)
end

return T
