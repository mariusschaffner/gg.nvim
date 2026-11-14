-- The editing foundation: the change runner and the confirmation / menu
-- helpers.
local H = require("tests.helpers")
local confirm = require("gg.ui.components.confirm")
local edit = require("gg.ui.detail.edit")
local task = require("gg.core.task")
local sel = require("tests.support.select")
local eq = MiniTest.expect.equality

local saved = {}
local notes

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      saved = { notify = vim.notify, input = vim.ui.input, select = vim.ui.select }
      notes = {}
      vim.notify = function(msg, level)
        table.insert(notes, { msg, level })
      end
    end,
    post_case = function()
      vim.notify, vim.ui.input, vim.ui.select = saved.notify, saved.input, saved.select
    end,
  },
})

T["messages"] = function()
  local busy, ok, fail = edit.messages("title")
  eq({ busy, ok, fail("boom") }, { "Updating title…", "Title updated", "Title update failed: boom" })
end

T["run: success applies the result, tells the stack, redraws"] = function()
  local log = {}
  local t = edit.run({
    what = "labels",
    task = function()
      return task.resolved({ labels = { "a" } })
    end,
    apply = function(r)
      table.insert(log, "apply:" .. r.labels[1])
    end,
    rollback = function()
      table.insert(log, "rollback")
    end,
    changed = function()
      table.insert(log, "changed")
    end,
    render = function()
      table.insert(log, "render")
    end,
    done = function(_, err)
      table.insert(log, "done:" .. tostring(err))
    end,
  })
  H.await(t)
  H.flush()
  eq(log, { "apply:a", "changed", "render", "done:nil" })
  eq(notes, { { "gg.ui: Updating labels…", vim.log.levels.INFO }, { "gg.ui: Labels updated", vim.log.levels.INFO } })
end

T["run: failure rolls back and shows the error"] = function()
  local log = {}
  local t = edit.run({
    what = "description",
    task = function()
      return task.failed(require("gg").errors.new("forbidden", "403 Forbidden"))
    end,
    apply = function()
      table.insert(log, "apply")
    end,
    rollback = function(err)
      table.insert(log, "rollback:" .. err.kind)
    end,
    changed = function()
      table.insert(log, "changed")
    end,
    render = function()
      table.insert(log, "render")
    end,
  })
  H.await(t)
  H.flush()
  eq(log, { "rollback:forbidden", "render" })
  eq(notes[2], { "gg.ui: Description update failed: 403 Forbidden", vim.log.levels.ERROR })
end

T["run: a closed view takes nothing; custom notices"] = function()
  local applied = false
  H.await(edit.run({
    what = "title",
    task = function()
      return task.resolved(1)
    end,
    apply = function()
      applied = true
    end,
    alive = function()
      return false
    end,
  }))
  H.flush()
  eq(applied, false)
  H.await(edit.run({
    what = "state",
    busy = "Closing issue…",
    success = "Issue closed",
    task = function()
      return task.resolved(1)
    end,
  }))
  H.flush()
  eq(#notes, 3) -- the closed view: only its "Updating" notice
  eq({ notes[2][1], notes[3][1] }, { "gg.ui: Closing issue…", "gg.ui: Issue closed" })
  edit.refuse("Issue is closed")
  eq(notes[4], { "gg.ui: Issue is closed", vim.log.levels.WARN })
end

T["confirm.ask: only yes runs"] = function()
  local prompts, ran = {}, 0
  local answer
  vim.ui.input = function(opts, cb)
    table.insert(prompts, opts.prompt)
    cb(answer)
  end
  for _, a in ipairs({ "y", " Yes", "n", "", false }) do
    answer = a or nil
    confirm.ask("Merge !12?", function()
      ran = ran + 1
    end)
  end
  eq(ran, 2)
  eq(prompts[1], "Merge !12? [y/N]: ")
end

T["confirm.menu: picks, confirms when asked, empty says so"] = function()
  local ran = {}
  vim.ui.input = function(_, cb)
    cb("y")
  end
  local items = {
    { label = "Close", confirm = "Close #1?", run = function()
      table.insert(ran, "close")
    end },
    { label = "Reopen", run = function()
      table.insert(ran, "reopen")
    end },
  }
  local home = vim.api.nvim_get_current_win()
  confirm.menu("Actions", items)
  local prompt_win, list_win = sel.wait()
  eq(vim.api.nvim_win_get_config(prompt_win).title[1][1], " Actions ")
  eq(sel.offered(), { "Close", "Reopen" })
  eq(vim.api.nvim_win_get_height(list_win), 2) -- as high as the entries
  sel.choose("Close")
  eq(vim.api.nvim_get_current_win(), home)
  confirm.menu("Actions", items)
  sel.choose("Reopen")
  confirm.menu("Actions", items)
  sel.cancel()
  eq(ran, { "close", "reopen" })
  -- an editor too small for the list: vim.ui.select
  local lines_ = vim.o.lines
  vim.o.lines = 5
  local asked
  vim.ui.select = function(list, opts, cb)
    asked = { opts.prompt, vim.tbl_map(opts.format_item, list) }
    cb(list[2])
  end
  confirm.menu("Actions", items)
  vim.o.lines = lines_
  eq(asked, { "Actions", { "Close", "Reopen" } })
  eq(ran, { "close", "reopen", "reopen" })
  confirm.menu("Actions", {})
  eq(notes[#notes][1], "gg.ui: no actions available")
end

return T
