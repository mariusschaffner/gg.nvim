--- New issue: a title and a description. A milestone or labels passed by
--- the caller (`preset`) are sent along without being shown.
local gg = require("gg")

---@type gg.ui.CreateDef
return {
  kind = "issue",
  accent = "GitlabCreateIssue",
  icon = "＋",
  label = "New issue",
  entity = "Issue",
  title = { placeholder = "title" },
  fields = {},
  body = { filetype = "markdown" },
  submit_label = "Create",
  busy_label = "creating…",
  api_fields = { title = "title", description = "body" },
  changed = { "issue", "milestone" },
  hints = function(p)
    return {
      { key = p:key("create_next_field"), desc = "Title ⇄ description" },
      { key = p:key("create_cancel"), desc = "Cancel" },
    }
  end,
  setup = function(p)
    if p.preset.title then
      p:set_title(p.preset.title)
    end
    if p.preset.description then
      p:set_body(vim.split(p.preset.description, "\n", { plain = true }))
    end
    p:start()
  end,
  submit = function(p, v)
    return gg.issues.create({
      host = p.ctx.host,
      project = p.ctx.project,
      title = v.title,
      description = v.description ~= "" and v.description or nil,
      milestone_id = p.preset.milestone_id,
      labels = p.preset.labels,
    })
  end,
  show = function(ctx, issue)
    require("gg.ui.detail").issue(ctx, issue)
  end,
}
