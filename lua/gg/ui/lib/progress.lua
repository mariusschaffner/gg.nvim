--- Segment progress bars: "● ● ● ○ ○". Pure.
local M = {}

M.DONE = "●"
M.TODO = "○"

---@alias gg.ui.Segments { [1]: string, [2]: string|nil }[]

--- `done` of `total` as `n` space-separated dots (default: one per item,
--- at most 10). Filled dots are rounded down so a bar is only full when
--- everything is done.
---@param done integer
---@param total integer
---@param n? integer
---@return gg.ui.Segments
function M.dots(done, total, n)
  n = n or math.min(math.max(total, 1), 10)
  local filled = total > 0 and math.floor(done / total * n) or 0
  if done >= total and total > 0 then
    filled = n
  end
  local out = {}
  for i = 1, n do
    if i > 1 then
      table.insert(out, { " ", nil })
    end
    if i <= filled then
      table.insert(out, { M.DONE, "GitlabProgressDone" })
    else
      table.insert(out, { M.TODO, "GitlabProgressTodo" })
    end
  end
  return out
end

--- Three buckets as `n` dots (default: one per item, at most 20): done
--- (green), doing (purple), then todo. Rounding leftovers go to todo.
---@param done integer
---@param doing integer
---@param todo integer
---@param n? integer
---@return gg.ui.Segments
function M.buckets(done, doing, todo, n)
  local total = done + doing + todo
  n = n or math.min(math.max(total, 1), 20)
  local d, g = 0, 0
  if total > 0 then
    d = math.floor(done / total * n + 0.5)
    g = math.floor(doing / total * n + 0.5)
    if d + g > n then
      g = n - d
    end
  end
  local out = {}
  for i = 1, n do
    if i > 1 then
      table.insert(out, { " ", nil })
    end
    if i <= d then
      table.insert(out, { M.DONE, "GitlabProgressDone" })
    elseif i <= d + g then
      table.insert(out, { M.DONE, "GitlabProgressDoing" })
    else
      table.insert(out, { M.TODO, "GitlabProgressTodo" })
    end
  end
  return out
end

return M
