--- A GitLab job log, parsed into lines with highlights and sections. Pure.
---
--- Fed incrementally (`feed`): only complete lines are parsed, the rest
--- waits for the next chunk (`finish` flushes it). Per line:
---   * CRLF becomes LF; for a `\r` inside a line only the text after the
---     last one is kept (terminal redraw), except the title of a
---     `section_start` marker.
---   * OSC/DCS sequences, every CSI sequence except SGR and control bytes
---     are removed; SGR colours become highlight spans. Lines without any
---     colour are classified (errors, warnings, commands, success).
---   * `section_start:<t>:<key>` opens a section with a "▾ title" row;
---     `section_end:<t>:<key>` closes it (its duration goes on that row).
---   * lines with ERROR / WARNING (or classified as errors) are tinted.
local date = require("gg.ui.lib.date")
local doc = require("gg.ui.lib.doc")
local line = require("gg.ui.lib.line")

local M = {}

M.SECTION = "▾"

local ESC = "\27"

local FG = {
  [30] = "GitlabAnsiBlack",
  [31] = "GitlabAnsiRed",
  [32] = "GitlabAnsiGreen",
  [33] = "GitlabAnsiYellow",
  [34] = "GitlabAnsiBlue",
  [35] = "GitlabAnsiMagenta",
  [36] = "GitlabAnsiCyan",
  [37] = "GitlabAnsiWhite",
}
for i = 90, 97 do
  FG[i] = FG[i - 60]
end

--- Remove every escape sequence but SGR, and control bytes but TAB / ESC.
---@param s string
---@return string
function M.strip_controls(s)
  s = s:gsub(ESC .. "%][^\7\27]*\7", "") -- OSC ... BEL
  s = s:gsub(ESC .. "%][^\27]*" .. ESC .. "\\", "") -- OSC ... ST
  s = s:gsub(ESC .. "P[^\27]*" .. ESC .. "\\", "") -- DCS ... ST
  s = s:gsub(ESC .. "%[[%d;?]*[A-Za-ln-z@`]", "") -- CSI that is not SGR
  s = s:gsub("[%z\1-\8\11-\26\28-\31\127]", "")
  return s
end

--- Plain text and highlight spans of a line with SGR sequences.
---@param s string
---@return string text
---@return { [1]: integer, [2]: integer, [3]: string }[] spans 0-based byte ranges
function M.ansi(s)
  local out, spans = {}, {}
  local bytes = 0
  local fg, bold = nil, false
  local pos = 1
  local function current()
    return fg or (bold and "GitlabAnsiBold" or nil)
  end
  local function emit(piece)
    if piece == "" then
      return
    end
    local hl = current()
    if hl then
      local last = spans[#spans]
      if last and last[3] == hl and last[2] == bytes then
        last[2] = bytes + #piece
      else
        table.insert(spans, { bytes, bytes + #piece, hl })
      end
    end
    table.insert(out, piece)
    bytes = bytes + #piece
  end
  while true do
    local a, b, params = s:find(ESC .. "%[([%d;]*)m", pos)
    if not a then
      emit((s:sub(pos):gsub(ESC, "")))
      break
    end
    emit((s:sub(pos, a - 1):gsub(ESC, "")))
    local codes = vim.split(params == "" and "0" or params, ";", { plain = true })
    local i = 1
    while i <= #codes do
      local n = tonumber(codes[i]) or 0
      if n == 0 then
        fg, bold = nil, false
      elseif n == 1 then
        bold = true
      elseif n == 22 then
        bold = false
      elseif n == 39 then
        fg = nil
      elseif FG[n] then
        fg = FG[n]
      elseif n == 38 or n == 48 then
        -- 256 colours (5;n) or true colour (2;r;g;b): skipped
        local kind = tonumber(codes[i + 1])
        i = i + (kind == 5 and 2 or kind == 2 and 4 or 1)
      end
      i = i + 1
    end
    pos = b + 1
  end
  return table.concat(out), spans
end

--- The highlight of a line without colours, or nil.
---@param s string
---@return string|nil
function M.classify(s)
  local l = s:lower()
  if l:match("^%s*error[:%s]") or l:find("job failed", 1, true) or l:match("exit code [1-9]") or l:match("^%s*fatal:") then
    return "GitlabLogError"
  elseif l:match("^%s*warning[:%s]") or l:find("deprecated", 1, true) then
    return "GitlabLogWarn"
  elseif s:match("^%$ ") or s:match("^%+ ") then
    return "GitlabLogInfo"
  elseif l:find("job succeeded", 1, true) or l:match("exit code 0") then
    return "GitlabLogOk"
  end
  return nil
end

---@class gg.ui.LogLine
---@field text string
---@field spans { [1]: integer, [2]: integer, [3]: string }[]
---@field tint string|nil whole-line background
---@field section integer|nil index of the section this row heads

---@class gg.ui.LogSection
---@field key string
---@field title string
---@field head integer 1-based line of its "▾" row
---@field last integer|nil last line, once closed
---@field started integer epoch seconds
---@field duration integer|nil seconds, once closed

---@class gg.ui.LogModel
---@field lines gg.ui.LogLine[]
---@field sections gg.ui.LogSection[]
---@field first_error integer|nil 1-based line of the first error
---@field private _pending string
---@field private _open table<string, integer> section key -> index
---@field private _started boolean
local Log = {}
Log.__index = Log

--- An empty log.
---@return gg.ui.LogModel
function M.new()
  return setmetatable({ lines = {}, sections = {}, _pending = "", _open = {}, _started = false }, Log)
end

---@private
function Log:_push(text, spans, extra)
  local l = { text = text, spans = spans or {} }
  for k, v in pairs(extra or {}) do
    l[k] = v
  end
  table.insert(self.lines, l)
  return #self.lines
end

---@private
function Log:_line(raw)
  if not self._started then
    self._started = true
    raw = raw:gsub("^\239\187\191", "") -- BOM
  end
  raw = raw:gsub(ESC .. "%[0?K", "")
  -- section markers (the rest of the line after them is regular text)
  local t, key, rest = raw:match("section_start:(%d+):([%w_%.%-]+)[^\r]*\r?(.*)$")
  if t then
    local title = M.ansi(M.strip_controls(rest))
    title = title ~= "" and title or key
    table.insert(self.sections, { key = key, title = title, started = tonumber(t) })
    local idx = #self.sections
    self.sections[idx].head = self:_push(title, {}, { section = idx })
    self._open[key] = idx
    return
  end
  local et, ekey, erest = raw:match("section_end:(%d+):([%w_%.%-]+)\r?(.*)$")
  if et then
    local idx = self._open[ekey]
    if idx then
      local sec = self.sections[idx]
      sec.last = #self.lines
      sec.duration = math.max(0, tonumber(et) - sec.started)
      self._open[ekey] = nil
    end
    raw = erest or ""
    if raw:match("^%s*$") then
      return
    end
  end
  -- a carriage return redraws the line: keep the last non-empty part
  if raw:find("\r", 1, true) then
    local parts = vim.split(raw, "\r", { plain = true })
    local keep = parts[#parts]
    for i = #parts, 1, -1 do
      if parts[i] ~= "" then
        keep = parts[i]
        break
      end
    end
    raw = keep
  end
  local text, spans = M.ansi(M.strip_controls(raw))
  text = text:gsub("\t", "    ")
  local tint
  local class = #spans == 0 and M.classify(text) or nil
  if class then
    spans = { { 0, #text, class } }
  end
  if text:find("ERROR", 1, true) or class == "GitlabLogError" then
    tint = "GitlabLogErrorLine"
  elseif text:find("WARNING", 1, true) then
    tint = "GitlabLogWarnLine"
  end
  local n = self:_push(text, spans, { tint = tint })
  if tint == "GitlabLogErrorLine" and not self.first_error then
    self.first_error = n
  end
end

--- Feed a chunk of the raw log.
---@param chunk string
function Log:feed(chunk)
  local data = self._pending .. chunk
  data = data:gsub("\r\n", "\n")
  -- a trailing "\r" may be the first half of "\r\n"
  local keep_cr = data:sub(-1) == "\r"
  if keep_cr then
    data = data:sub(1, -2)
  end
  local start = 1
  while true do
    local nl = data:find("\n", start, true)
    if not nl then
      break
    end
    self:_line(data:sub(start, nl - 1))
    start = nl + 1
  end
  self._pending = data:sub(start) .. (keep_cr and "\r" or "")
end

--- Parse what is left (the log is complete).
function Log:finish()
  local rest = self._pending:gsub("\r$", "")
  self._pending = ""
  if rest ~= "" then
    self:_line(rest)
  end
end

--- True when nothing has been parsed.
---@return boolean
function Log:empty()
  return #self.lines == 0 and self._pending == ""
end

--- The log as a document. Section rows read "▾ title · 3s".
---@return gg.ui.Doc doc
---@return { [1]: integer, [2]: integer }[] folds closed sections as 1-based line ranges
function Log:render()
  local d = doc.new()
  local folds = {}
  for _, l in ipairs(self.lines) do
    if l.section then
      local sec = self.sections[l.section]
      local ln = line.new():add(M.SECTION .. " " .. l.text, "GitlabLogSection")
      if sec.duration then
        ln:add((" · %s"):format(date.clock(sec.duration)), "GitlabDetailMuted")
      end
      d:line(ln, { section = l.section })
      if sec.last and sec.last > sec.head then
        table.insert(folds, { sec.head, sec.last })
      end
    else
      local lnum = d:line(line.new():add(l.text))
      for _, sp in ipairs(l.spans) do
        table.insert(d.marks, { row = lnum - 1, col = sp[1], end_col = sp[2], hl = sp[3] })
      end
      if l.tint then
        d:line_hl(lnum, l.tint)
      end
    end
  end
  return d, folds
end

--- The first line where two renders differ (1-based), or nil when equal.
---@param old string[]
---@param new string[]
---@return integer|nil
function M.first_diff(old, new)
  local n = math.max(#old, #new)
  for i = 1, n do
    if old[i] ~= new[i] then
      return i
    end
  end
  return nil
end

return M
