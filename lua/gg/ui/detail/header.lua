--- The header of a detail view, and the titles of its windows. Pure.
---
--- The header is a bordered float. Its border title carries the breadcrumb
--- on the left and meta text on the right; its body has the title line
--- (pill, title, reference), an optional chip row, an optional meta strip
--- (narrow windows) and an optional extra block (strips, the pipeline graph).
local doc = require("gg.ui.lib.doc")
local line = require("gg.ui.lib.line")
local text = require("gg.ui.lib.text")

local M = {}

M.FILL = "─"
M.BORDER_HL = "GitlabPickerBorder"
M.MIN_CRUMB = 20

---@alias gg.ui.Segs { [1]: string, [2]: string|nil }[]

local function segs_width(segs)
  local w = 0
  for _, s in ipairs(segs) do
    w = w + text.width(s[1])
  end
  return w
end

-- the last `max` cells of `s`, starting with "…" when cut
local function tail(s, max)
  if text.width(s) <= max then
    return s
  end
  local n = vim.fn.strchars(s)
  local out = ""
  for i = n - 1, 0, -1 do
    local ch = vim.fn.strcharpart(s, i, 1)
    if text.width(text.ELLIPSIS .. ch .. out) > max then
      break
    end
    out = ch .. out
  end
  return text.ELLIPSIS .. out
end

--- "group/sub / project › issues › " for a project path and a kind.
---@param project string|nil full path
---@param kind string e.g. "issues"
---@return string
function M.crumb(project, kind)
  project = project or ""
  local ns, name = project:match("^(.*)/([^/]+)$")
  local base = ns and (ns .. " / " .. name) or project
  if base == "" then
    return kind .. " › "
  end
  return ("%s › %s › "):format(base, kind)
end

--- Border title chunks exactly `width` cells wide: " crumb #ref ──── meta ".
--- The crumb is cut from the start first (down to 20 cells), then the meta
--- is dropped.
---@param width integer cells between the corners
---@param crumb string
---@param ref string e.g. "#17"
---@param meta? gg.ui.Segs right-aligned
---@return gg.ui.Chunk[]
function M.border_title(width, crumb, ref, meta)
  meta = meta or {}
  local left_w = 1 + text.width(crumb) + text.width(ref) + 1
  local meta_w = #meta > 0 and (segs_width(meta) + 2) or 0
  if left_w + meta_w + 1 > width then
    local room = width - 1 - meta_w - text.width(ref) - 2
    if room >= M.MIN_CRUMB then
      crumb = tail(crumb, room)
    else
      meta, meta_w = {}, 0
      crumb = tail(crumb, math.max(0, width - 1 - text.width(ref) - 2))
    end
    left_w = 1 + text.width(crumb) + text.width(ref) + 1
  end
  local out = {
    { " " .. crumb, "GitlabDetailBreadcrumb" },
    { ref .. " ", "GitlabDetailRef" },
  }
  local fill = width - left_w - meta_w
  if #meta > 0 then
    table.insert(out, { text.rep(M.FILL, math.max(0, fill)), M.BORDER_HL })
    table.insert(out, { " ", "GitlabDetailMeta" })
    for _, s in ipairs(meta) do
      table.insert(out, { s[1], s[2] or "GitlabDetailMeta" })
    end
    table.insert(out, { " ", "GitlabDetailMeta" })
  end
  return out
end

---@class gg.ui.TabSpec
---@field key string
---@field label string
---@field count? integer|string

--- Tab bar chunks for a window title: " Description  Activity 12 ".
---@param tabs gg.ui.TabSpec[]
---@param active string
---@return gg.ui.Chunk[]
function M.tabs_title(tabs, active)
  local out = { { " ", M.BORDER_HL } }
  for i, t in ipairs(tabs) do
    if i > 1 then
      table.insert(out, { " ", M.BORDER_HL })
    end
    local label = t.count ~= nil and ("%s %s"):format(t.label, tostring(t.count)) or t.label
    table.insert(out, { " " .. label .. " ", t.key == active and "GitlabTabActive" or "GitlabDetailTab" })
  end
  table.insert(out, { " ", M.BORDER_HL })
  return out
end

---@class gg.ui.HeaderInput
---@field width integer inner width of the header window
---@field pill { [1]: string, [2]: string } " ● Open "
---@field title string
---@field ref string "#17"
---@field title_right? gg.ui.Segs right-aligned on the title line
---@field chips? gg.ui.Segs one row of chips (cut to the width)
---@field strip? string meta strip for narrow windows (dim)
---@field extra? gg.ui.Doc a block below everything else

--- The header body.
---@param input gg.ui.HeaderInput
---@return gg.ui.Doc
function M.build(input)
  local d = doc.new()
  local width = math.max(10, input.width)
  local inner = width - 2 -- one cell of padding on both sides
  local right = input.title_right or {}
  local right_w = #right > 0 and segs_width(right) + 2 or 0
  local l = line.new():add(" ")
  l:add(input.pill[1], input.pill[2]):add(" ")
  local used = text.width(input.pill[1]) + 1
  local ref = " " .. input.ref
  local title_room = inner - used - text.width(ref) - right_w
  if title_room < 8 and right_w > 0 then
    right, right_w = {}, 0
    title_room = inner - used - text.width(ref)
  end
  local title = text.truncate(text.clean(input.title), math.max(1, title_room))
  l:add(title, "GitlabDetailTitle"):add(ref, "GitlabDetailMuted")
  if right_w > 0 then
    l:pad_to(1 + inner - right_w + 2)
    for _, s in ipairs(right) do
      l:add(s[1], s[2])
    end
  end
  d:line(l)
  if input.chips and #input.chips > 0 then
    d:blank()
    d:line(line.new():add(" "):segments(input.chips, inner))
  end
  if input.strip and input.strip ~= "" then
    d:line(line.new():add(" "):add(text.truncate(input.strip, inner), "GitlabDetailMuted"))
  end
  if input.extra and #input.extra.lines > 0 then
    d:blank()
    d:append(input.extra)
  end
  return d
end

return M
