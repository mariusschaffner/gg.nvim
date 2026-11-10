--- The pure side of editing: parsing what was typed into a field, the
--- payloads for GitLab, task toggles, branch names, completion matching and
--- which actions apply. Pure.
local M = {}

--- The values of a comma-separated field: trimmed, empty ones dropped,
--- duplicates (case-insensitive) dropped, in order. A leading "@" or "~"
--- (usernames, labels) is dropped too.
---@param text string|nil
---@return string[]
function M.split(text)
  local out, seen = {}, {}
  for part in tostring(text or ""):gmatch("[^,]+") do
    local v = vim.trim(part):gsub("^[@~]", "")
    v = vim.trim(v)
    local key = v:lower()
    if v ~= "" and not seen[key] then
      seen[key] = true
      table.insert(out, v)
    end
  end
  return out
end

--- The value being typed at byte column `col` (0-based, the cursor) of a
--- field line: its start column (0-based) and the text so far, without the
--- leading spaces (and "@" / "~"). Single-value fields use the whole line.
---@param line string
---@param col integer
---@param multi boolean
---@return integer start
---@return string query
function M.token(line, col, multi)
  local before = line:sub(1, col)
  local start = 0
  if multi then
    local comma = before:match(".*(),")
    if comma then
      start = comma
    end
  end
  local lead = before:sub(start + 1):match("^%s*[@~]?")
  start = start + #lead
  return start, before:sub(start + 1)
end

--- What a set of names changes: the added and the removed ones
--- (case-insensitive, original spelling kept).
---@param old string[]
---@param new string[]
---@return string[] added
---@return string[] removed
function M.diff(old, new)
  local function set(list)
    local s = {}
    for _, v in ipairs(list) do
      s[v:lower()] = true
    end
    return s
  end
  local o, n = set(old), set(new)
  local added, removed = {}, {}
  for _, v in ipairs(new) do
    if not o[v:lower()] then
      table.insert(added, v)
    end
  end
  for _, v in ipairs(old) do
    if not n[v:lower()] then
      table.insert(removed, v)
    end
  end
  return added, removed
end

--- Find typed `names` among `items` by `key(item)` (case-insensitive).
---@generic T
---@param names string[]
---@param items T[]
---@param key fun(item: T): string|nil
---@return T[] found in the order typed
---@return string[] unknown the names without a match
function M.resolve(names, items, key)
  local by = {}
  for _, it in ipairs(items or {}) do
    local k = key(it)
    if k then
      by[k:lower()] = by[k:lower()] or it
    end
  end
  local found, unknown = {}, {}
  for _, n in ipairs(names) do
    local it = by[n:lower()]
    if it then
      table.insert(found, it)
    else
      table.insert(unknown, n)
    end
  end
  return found, unknown
end

---@class gg.ui.Candidate
---@field word string inserted
---@field menu? string shown beside it (e.g. the user's name)

--- The candidates matching `query`: prefixes first, then substrings
--- (case-insensitive), at most `max`; `exclude` drops already typed values.
---@param query string
---@param candidates gg.ui.Candidate[]
---@param exclude? string[]
---@param max? integer default 50
---@return gg.ui.Candidate[]
function M.match(query, candidates, exclude, max)
  local q = query:lower()
  local skip = {}
  for _, v in ipairs(exclude or {}) do
    skip[v:lower()] = true
  end
  local pre, sub = {}, {}
  for _, c in ipairs(candidates) do
    local w = c.word:lower()
    local m = (c.menu or ""):lower()
    if not skip[w] then
      if q == "" or vim.startswith(w, q) then
        table.insert(pre, c)
      elseif w:find(q, 1, true) or m:find(q, 1, true) then
        table.insert(sub, c)
      end
    end
  end
  local out = vim.list_extend(pre, sub)
  return vim.list_slice(out, 1, max or 50)
end

--- Toggle the task on source line `lnum` (`- [ ]` <-> `- [x]`) of `src`.
---@param src string
---@param lnum integer 1-based
---@return string|nil new source, nil when that line is no task
---@return boolean|nil done the task's new state
function M.toggle_task(src, lnum)
  local lines = vim.split(src:gsub("\r", ""), "\n", { plain = true })
  local l = lines[lnum]
  if not l then
    return nil
  end
  local pre, mark, post = l:match("^(%s*[-*+] %[)([ xX])(%].*)$")
  if not pre then
    return nil
  end
  local done = mark == " "
  lines[lnum] = pre .. (done and "x" or " ") .. post
  return table.concat(lines, "\n"), done
end

--- The default branch name for an issue: "<iid>-<slug of the title>",
--- lower case, at most 50 characters.
---@param iid integer
---@param title string|nil
---@return string
function M.branch_name(iid, title)
  local slug = tostring(title or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  local name = tostring(iid) .. (slug ~= "" and ("-" .. slug) or "")
  if #name > 50 then
    name = name:sub(1, 50):gsub("%-+$", "")
  end
  return name
end

--- A date typed into a field: "" clears it (false), "YYYY-MM-DD" sets it.
---@param text string
---@return string|false|nil date nil when the text is no date
function M.date(text)
  local t = vim.trim(text or "")
  if t == "" then
    return false
  end
  local y, m, d = t:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    return nil
  end
  m, d = tonumber(m), tonumber(d)
  if m < 1 or m > 12 or d < 1 or d > 31 then
    return nil
  end
  return t
end

--- The usernames to complete after "@" in a comment: the author, the
--- assignees and everyone who commented, each once, in that order.
---@param item { author?: gg.User, assignees?: gg.User[] }
---@param discussions? gg.Discussion[]
---@return gg.ui.Candidate[]
function M.mentions(item, discussions)
  local out, seen = {}, {}
  local function add(u)
    if u and u.username and not seen[u.username] then
      seen[u.username] = true
      table.insert(out, { word = u.username, menu = u.name })
    end
  end
  add(item.author)
  for _, u in ipairs(item.assignees or {}) do
    add(u)
  end
  for _, d in ipairs(discussions or {}) do
    for _, n in ipairs(d.notes or {}) do
      if not n.system then
        add(n.author)
      end
    end
  end
  return out
end

--- Who may change what on an item: `open` (the item can still change) and
--- which actions the `A` menu offers.
---@param kind "issue"|"milestone"|"merge_request"
---@param item table
---@return { open: boolean, actions: string[] }
function M.actions(kind, item)
  local state = item.state
  if kind == "issue" then
    local open = state ~= "closed"
    return { open = open, actions = { open and "close" or "reopen" } }
  elseif kind == "milestone" then
    local open = state ~= "closed"
    return { open = open, actions = { open and "close" or "activate" } }
  end
  local open = state == "opened" or state == "locked"
  local actions = {}
  if open then
    table.insert(actions, item.approved_by_me and "unapprove" or "approve")
    if not item.draft then
      table.insert(actions, "merge")
    end
    table.insert(actions, item.draft and "ready" or "draft")
    table.insert(actions, "close")
  elseif state == "closed" then
    table.insert(actions, "reopen")
  end
  return { open = open, actions = actions }
end

return M
