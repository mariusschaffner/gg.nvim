--- A tabs line: " Open 9 " (active) followed by the other tabs. Pure.
local M = {}

---@class gg.ui.TabItem
---@field key string
---@field label string
---@field count? integer|string nil shows "…" (loading)

--- Segments `{ text, hl }` for a tabs line. Every tab has `pad` spaces of
--- padding on each side (default 1), and tabs are one space apart.
---@param tabs gg.ui.TabItem[]
---@param active string key of the active tab
---@param opts? { hl?: string, active_hl?: string, pad?: integer }
---@return { [1]: string, [2]: string|nil }[]
function M.segments(tabs, active, opts)
  opts = opts or {}
  local out = {}
  local pad = string.rep(" ", opts.pad or 1)
  for i, t in ipairs(tabs) do
    if i > 1 then
      table.insert(out, { " ", nil })
    end
    local count = t.count == nil and "…" or tostring(t.count)
    local hl = t.key == active and (opts.active_hl or "GitlabTabActive") or (opts.hl or "GitlabTab")
    table.insert(out, { pad .. t.label .. " " .. count .. pad, hl })
  end
  return out
end

return M
