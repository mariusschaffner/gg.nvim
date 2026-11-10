--- The variables of a pipeline run, written one per line as `KEY = value`.
--- Pure.
local placeholders = require("gg.ui.create.placeholders")

local M = {}

M.KEY_PATTERN = "^[A-Za-z_][A-Za-z0-9_]*$"
--- The line `a` adds: both parts still to be written.
M.NEW_LINE = placeholders.wrap("KEY") .. " = " .. placeholders.wrap("value")

---@class gg.ui.VariableEntry
---@field lnum integer 1-based line
---@field key string
---@field value string

---@class gg.ui.VariableProblem
---@field lnum integer 1-based line
---@field col integer 0-based byte column
---@field end_col integer
---@field message string

--- The line for a variable.
---@param key string
---@param value string|nil
---@return string
function M.line(key, value)
  return ("%s = %s"):format(key, value or "")
end

--- Read the lines: the key is the text before the first `=`, the value the
--- rest, both trimmed. Blank lines are skipped. Lines without `=`, keys that
--- are not valid names (a `‹KEY›` placeholder among them) and keys that
--- appear twice are problems. A value that is still a placeholder is empty.
---@param lines string[]
---@return gg.ui.VariableEntry[] entries the valid lines, in order
---@return gg.ui.VariableProblem[] problems
function M.parse(lines)
  local entries, problems, seen = {}, {}, {}
  for lnum, line in ipairs(lines) do
    if vim.trim(line) ~= "" then
      local eq = line:find("=", 1, true)
      if not eq then
        table.insert(problems, { lnum = lnum, col = 0, end_col = #line, message = "expected KEY = value" })
      else
        local raw_key = line:sub(1, eq - 1)
        local key = vim.trim(raw_key)
        local value = vim.trim(line:sub(eq + 1))
        local key_col = #raw_key - #raw_key:gsub("^%s+", "")
        if placeholders.is(value) then
          value = ""
        end
        if not key:match(M.KEY_PATTERN) then
          local why = key == "" and "the key is missing" or ("invalid key %q: letters, digits and _ only, not starting with a digit"):format(key)
          table.insert(problems, { lnum = lnum, col = key_col, end_col = math.max(key_col + #key, key_col + 1), message = why })
        elseif seen[key] then
          table.insert(problems, { lnum = lnum, col = key_col, end_col = key_col + #key, message = ("%s is already set on line %d"):format(key, seen[key]) })
        else
          seen[key] = lnum
          table.insert(entries, { lnum = lnum, key = key, value = value })
        end
      end
    end
  end
  return entries, problems
end

--- How many lines hold something (for the `Variables · N` label).
---@param lines string[]
---@return integer
function M.count(lines)
  local n = 0
  for _, line in ipairs(lines) do
    if vim.trim(line) ~= "" then
      n = n + 1
    end
  end
  return n
end

--- The variables as `gg.pipelines.create` takes them. `types[lnum]` is
--- "file" for a file variable; everything else is a plain variable.
---@param entries gg.ui.VariableEntry[]
---@param types table<integer, string>
---@return gg.PipelineVariable[]
function M.payload(entries, types)
  local out = {}
  for _, e in ipairs(entries) do
    table.insert(out, { key = e.key, value = e.value, type = types[e.lnum] == "file" and "file" or "env_var" })
  end
  return out
end

return M
