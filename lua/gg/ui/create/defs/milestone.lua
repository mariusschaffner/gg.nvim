--- New milestone: a title, a start and a due date, a description.
local gg = require("gg")
local model = require("gg.ui.create.model")

local function pick_date(p, field)
  p:edit_field(field.id, function(text)
    local value = model.date(text)
    if value == nil then
      return nil, ("%s: not a date (use 2026-11-20 or 20.11.2026)"):format(field.label)
    end
    return value
  end)
end

---@type gg.ui.CreateDef
return {
  kind = "milestone",
  accent = "GitlabCreateMilestone",
  icon = "＋",
  label = "New milestone",
  entity = "Milestone",
  title = { placeholder = "title" },
  fields = {
    { id = "start", keymap = "create_start_date", label = "Start", hl = "GitlabDetailDate", empty = "yyyy-mm-dd", pick = pick_date },
    { id = "due", keymap = "create_due_date", label = "Due", hl = "GitlabDetailDate", empty = "yyyy-mm-dd", pick = pick_date },
  },
  body = { filetype = "markdown" },
  submit_label = "Create",
  busy_label = "creating…",
  api_fields = { title = "title", description = "body", start_date = "field_start", due_date = "field_due" },
  changed = { "milestone", "issue" },
  hints = function(p)
    return {
      { key = p:key("create_next_field"), desc = "Next field" },
      { key = p:key("create_cancel"), desc = "Cancel" },
    }
  end,
  setup = function(p)
    local pre = p.preset
    if pre.title then
      p:set_title(pre.title)
    end
    if pre.description then
      p:set_body(vim.split(pre.description, "\n", { plain = true }))
    end
    if pre.start_date then
      p:set_field("start", pre.start_date, nil, { prefill = true })
    end
    if pre.due_date then
      p:set_field("due", pre.due_date, nil, { prefill = true })
    end
    p:start()
  end,
  validate = function(_, v)
    -- ISO dates compare as text
    if v.fields.start and v.fields.due and v.fields.due < v.fields.start then
      return "The due date is before the start date", "field_due"
    end
  end,
  submit = function(p, v)
    return gg.milestones.create({
      host = p.ctx.host,
      project = p.ctx.project,
      title = v.title,
      description = v.description ~= "" and v.description or nil,
      start_date = v.fields.start,
      due_date = v.fields.due,
    })
  end,
  show = function(ctx, milestone)
    require("gg.ui.detail").milestone(ctx, milestone)
  end,
}
