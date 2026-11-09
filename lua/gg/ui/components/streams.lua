--- Parallel paged loading, one stream per state (e.g. opened / closed).
---
--- Each stream asks for a small first page (the table draws quickly), then
--- full pages, until the list ends or `limit` items are in. On a refresh the
--- old items stay until each stream has finished, then that state's items
--- are replaced. A cursor that comes back twice stops the stream with an
--- error instead of looping.
---
--- The functions work on the view itself, which keeps the stream state in
--- its own fields: `states`, `pending`, `tasks`, `by_state`, `refreshing`,
--- `loaded`, `truncated_by`, `truncated`, `gen`, `status`, `err_msg`.
local M = {}

M.FIRST_PAGE = 20
M.PAGE = 100

---@class gg.ui.StreamOpts
---@field fetch fun(state: string, cursor: string|nil, per_page: integer): gg.Task resolves with gg.Page
---@field limit integer upper bound per state
---@field has_items boolean the view shows loaded items now (a reload is a refresh)
---@field on_update fun(items: table[]) every loaded item (all states, in `states` order)
---@field on_error fun(err: gg.Error)
---@field on_start? fun() after the state is reset, before the first request

--- Set up the stream fields on `view`.
---@param view table
---@param states string[]
function M.init(view, states)
  view.states = states
  view.pending = {}
  for _, s in ipairs(states) do
    view.pending[s] = false
  end
  view.tasks = {}
  view.truncated = false
  view.truncated_by = {}
  view.refreshing = false
  view.loaded = 0
  view.gen = 0
end

--- Cancel every request in flight.
---@param view table
function M.cancel(view)
  for state, t in pairs(view.tasks) do
    t:cancel()
    view.tasks[state] = nil
  end
end

-- a page arrived or a stream finished
local function loaded(view, o)
  view.truncated = false
  for _, s in ipairs(view.states) do
    if view.truncated_by[s] == true then
      view.truncated = true
    end
  end
  local was_refreshing = view.refreshing
  local any, all_pending = false, true
  for _, s in ipairs(view.states) do
    any = any or view.pending[s]
    all_pending = all_pending and view.pending[s]
  end
  if not any then
    view.refreshing = false
  end
  if was_refreshing and view.refreshing and all_pending then
    return -- refreshing and no stream finished yet: nothing new to show
  end
  local all = {}
  for _, s in ipairs(view.states) do
    vim.list_extend(all, view.by_state[s])
  end
  o.on_update(all)
end

local function failed(view, o, err)
  M.cancel(view)
  for _, s in ipairs(view.states) do
    view.pending[s] = false
  end
  view.refreshing = false
  o.on_error(err)
end

local function stream(view, o, state, gen, into)
  local seen = {}
  local function step(cursor)
    local per_page = math.min(cursor and M.PAGE or M.FIRST_PAGE, o.limit - #into)
    local t = o.fetch(state, cursor, per_page)
    view.tasks[state] = t
    t:on_done(function(page, err)
      if view.closed or gen ~= view.gen then
        return
      end
      if err then
        return failed(view, o, err)
      end
      local items = page.items or {}
      local take = math.min(#items, o.limit - #into)
      for i = 1, take do
        into[#into + 1] = items[i]
      end
      view.loaded = view.loaded + take
      local next_cursor = page.next_cursor
      if next_cursor and seen[next_cursor] then
        return failed(view, o, { message = "pagination did not advance (the same cursor came back twice)" })
      end
      if next_cursor and #into < o.limit then
        seen[next_cursor] = true
        step(next_cursor)
      else
        view.tasks[state] = nil
        view.pending[state] = false
        view.truncated_by[state] = take < #items or next_cursor ~= nil
        if view.refreshing then
          view.by_state[state] = into
        end
      end
      loaded(view, o)
    end)
  end
  step(nil)
end

--- (Re)load every state in parallel. On a first load (`has_items` false)
--- pages go straight into `view.by_state`; on a refresh into new lists that
--- replace the old ones when each stream is done.
---@param view table
---@param o gg.ui.StreamOpts
function M.start(view, o)
  M.cancel(view)
  view.gen = view.gen + 1
  local gen = view.gen
  view.err_msg, view.loaded, view.truncated_by = nil, 0, {}
  view.refreshing = o.has_items
  if not view.refreshing then
    view.by_state = {}
    for _, s in ipairs(view.states) do
      view.by_state[s] = {}
    end
  end
  local into = {}
  for _, s in ipairs(view.states) do
    view.pending[s] = true
    into[s] = view.refreshing and {} or view.by_state[s]
  end
  if o.on_start then
    o.on_start()
  end
  for _, s in ipairs(view.states) do
    stream(view, o, s, gen, into[s])
  end
end

return M
