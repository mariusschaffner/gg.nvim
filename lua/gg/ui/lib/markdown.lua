--- A small markdown renderer for descriptions. Pure.
---
--- Not CommonMark: headings, task items, bullets, fenced code, links and
--- hashtags, wrapped to a width. Every rendered line records the source
--- line it came from (`rows[l].src`).
---
---   ## Acceptance                                   2 of 3 done
---   ✓ write the runbook
---   ○ dry run on staging
---   • a bullet
---     – a nested bullet
local doc = require("gg.ui.lib.doc")
local line = require("gg.ui.lib.line")
local text = require("gg.ui.lib.text")

local M = {}

-- the open fence after a fence line `f` ("```" or "~~~"): opens one, or
-- closes the open one when it matches
local function toggle_fence(open, f)
  if open == nil then
    return f
  elseif open == f then
    return nil
  end
  return open
end

M.TASK_OPEN = "○"
M.TASK_DONE = "✓"
M.BULLET = "•"
M.SUB_BULLET = "–"

local function task_of(s)
  local indent, mark, rest = s:match("^(%s*)[-*+] %[([ xX])%]%s+(.*)$")
  if indent then
    return { indent = #indent, done = mark ~= " ", text = rest }
  end
  return nil
end

local function bullet_of(s)
  local indent, rest = s:match("^(%s*)[-*+]%s+(.*)$")
  if indent then
    return { indent = #indent, text = rest }
  end
  return nil
end

--- Done and total task items (`- [x]` / `- [ ]`) in `src`, outside fences.
---@param src string|nil
---@return integer done
---@return integer total
function M.tasks(src)
  local done, total, fence = 0, 0, nil
  for _, s in ipairs(vim.split(tostring(src or ""):gsub("\r", ""), "\n", { plain = true })) do
    local f = s:match("^%s*(```)") or s:match("^%s*(~~~)")
    if f then
      fence = toggle_fence(fence, f)
    elseif not fence then
      local t = task_of(s)
      if t then
        total = total + 1
        done = done + (t.done and 1 or 0)
      end
    end
  end
  return done, total
end

-- inline markup to plain text: links, images, bold/italic markers
local function inline(s)
  s = s:gsub("!?%[([^%]]*)%]%(([^%)]*)%)", "%1")
  s = s:gsub("%*%*(.-)%*%*", "%1"):gsub("__(.-)__", "%1")
  s = s:gsub("<!%-%-.-%-%->", ""):gsub("</?[%a][^>]*>", "")
  return s
end
M.inline = inline

-- segments of a text line: #hashtags highlighted, the rest in `hl`
local function hashtag_segments(s, hl)
  local segs, pos = {}, 1
  while true do
    local a, b = s:find("%f[#%w]#[%a][%w_%-]*", pos)
    if not a then
      break
    end
    if a > pos then
      table.insert(segs, { s:sub(pos, a - 1), hl })
    end
    table.insert(segs, { s:sub(a, b), "GitlabDetailHashtag" })
    pos = b + 1
  end
  if pos <= #s then
    table.insert(segs, { s:sub(pos), hl })
  end
  return segs
end

-- append wrapped text: `first` prefix segments on the first line, the
-- continuation lines indented by the prefix width
local function wrapped(d, opts)
  local avail = math.max(4, opts.width - opts.indent - text.width(opts.prefix_text))
  local lines = text.wrap(opts.text, avail)
  for i, s in ipairs(lines) do
    local l = line.new():add(string.rep(" ", opts.indent))
    if i == 1 then
      for _, p in ipairs(opts.prefix) do
        l:add(p[1], p[2])
      end
    else
      l:add(string.rep(" ", text.width(opts.prefix_text)))
    end
    for _, sg in ipairs(opts.hashtags and hashtag_segments(s, opts.hl) or { { s, opts.hl } }) do
      l:add(sg[1], sg[2])
    end
    local info = vim.tbl_extend("force", { src = opts.src }, opts.info or {})
    d:line(l, info)
  end
end

---@class gg.ui.MarkdownOpts
---@field width integer
---@field pad? integer left padding (default 1)
---@field empty? string text for an empty source (default "No description")
---@field replace? fun(src_lnum: integer, s: string): gg.ui.Doc|nil render a source line yourself (e.g. issue cards)

--- Render markdown `src`.
---@param src string|nil
---@param opts gg.ui.MarkdownOpts
---@return gg.ui.Doc
function M.render(src, opts)
  local d = doc.new()
  local pad = opts.pad or 1
  local width = math.max(10, opts.width - pad)
  local lines = vim.split(tostring(src or ""):gsub("\r", ""), "\n", { plain = true })
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end
  if #lines == 0 then
    d:text(string.rep(" ", pad) .. (opts.empty or "No description"), "GitlabDetailMuted")
    return d
  end
  local fence
  local prev_blank = false
  for i, s in ipairs(lines) do
    local f = s:match("^%s*(```)") or s:match("^%s*(~~~)")
    if f then
      fence = toggle_fence(fence, f)
      d:line(line.new():add(string.rep(" ", pad)):add(text.truncate(s, width), "GitlabDetailMuted"), { src = i })
      prev_blank = false
    elseif fence then
      d:line(line.new():add(string.rep(" ", pad)):add(text.truncate(text.clean(s), width), "GitlabDetailMuted"), { src = i })
    elseif s:match("^%s*$") then
      if not prev_blank then
        d:blank({ src = i })
      end
      prev_blank = true
    else
      prev_blank = false
      local custom = opts.replace and opts.replace(i, s)
      if custom then
        d:append(custom)
      else
        local heading = s:match("^%s*#+%s+(.*)$")
        local task = not heading and task_of(s)
        local bullet = not heading and not task and bullet_of(s)
        if heading then
          -- tasks right below (one blank line allowed): "n of m done"
          local done, total, j = 0, 0, i + 1
          if lines[j] and lines[j]:match("^%s*$") then
            j = j + 1
          end
          while lines[j] and task_of(lines[j]) do
            total = total + 1
            done = done + (task_of(lines[j]).done and 1 or 0)
            j = j + 1
          end
          local note = total > 0 and ("%d of %d done"):format(done, total) or ""
          local title = text.truncate(inline(heading), math.max(4, width - text.width(note) - 2))
          local l = line.new():add(string.rep(" ", pad)):add(title, "GitlabDetailAccent")
          if note ~= "" then
            l:pad_to(pad + width - text.width(note)):add(note, "GitlabDetailMuted")
          end
          d:line(l, { src = i, kind = "heading" })
        elseif task then
          local indent = pad + math.min(task.indent, 8)
          local glyph = task.done and M.TASK_DONE or M.TASK_OPEN
          wrapped(d, {
            width = pad + width,
            indent = indent,
            prefix = { { glyph, task.done and "GitlabTaskDone" or "GitlabTaskOpen" }, { " ", nil } },
            prefix_text = glyph .. " ",
            text = inline(task.text),
            hl = task.done and "GitlabTaskDoneText" or "GitlabDetailValue",
            src = i,
            info = { kind = "task", done = task.done },
          })
        elseif bullet then
          local nested = bullet.indent >= 2
          local glyph = nested and M.SUB_BULLET or M.BULLET
          wrapped(d, {
            width = pad + width,
            indent = pad + (nested and 2 or 0),
            prefix = { { glyph, "GitlabDetailMuted" }, { " ", nil } },
            prefix_text = glyph .. " ",
            text = inline(bullet.text),
            hl = "GitlabDetailValue",
            hashtags = true,
            src = i,
          })
        else
          local indent = #(s:match("^(%s*)") or "")
          wrapped(d, {
            width = pad + width,
            indent = pad + math.min(indent, 8),
            prefix = {},
            prefix_text = "",
            text = (inline(s):gsub("^%s+", "")),
            hl = "GitlabDetailValue",
            hashtags = true,
            src = i,
          })
        end
      end
    end
  end
  return d
end

return M
