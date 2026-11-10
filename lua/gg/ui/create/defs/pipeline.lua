--- Run pipeline: a branch or tag, and the variables of the run.
---
--- The ref defaults to the current git branch when GitLab has it, else to
--- the project's default branch. The variables the CI configuration of the
--- ref declares for manual runs are prefilled with their defaults; GitLab
--- reads them in the background, so they are asked for a few times.
local gg = require("gg")
local project = require("gg.ui.project")
local ref_picker = require("gg.ui.create.ref_picker")
local refs = require("gg.ui.create.refs")
local variables = require("gg.ui.create.variables")
local variables_view = require("gg.ui.create.variables_view")

-- asking for the CI variables: how often, and the pause in between
local TUNING = { tries = 4, retry_ms = 1000 }

-- the declared variables of `ref`, into the editor (while it is untouched)
local function load_config(p, ref, attempt)
  if p.closed or p:field("ref") ~= ref then
    return
  end
  p.data.config = gg.pipelines.config_variables({ host = p.ctx.host, project = p.ctx.project, ref = ref })
  p.data.config:on_done(function(res)
    if p.closed or p:field("ref") ~= ref or not res then
      return
    end
    if res.ready then
      p.data.editor:set_defaults(res.variables)
    elseif attempt < TUNING.tries then
      vim.defer_fn(function()
        load_config(p, ref, attempt + 1)
      end, TUNING.retry_ms)
    end
  end)
end

-- make `item` the ref: the field, the title, the variables
local function use(p, item, prefill)
  if p.closed then
    return
  end
  p:set_field("ref", item.name, ref_picker.note(item), { prefill = prefill })
  p:set_title("Run pipeline for ⎇ " .. item.name)
  load_config(p, item.name, 1)
end

-- the project's default branch as the ref
local function use_default(p)
  p.data.project = gg.projects.get({ host = p.ctx.host, project = p.ctx.project })
  p.data.project:on_done(function(proj)
    local name = proj and proj.default_branch
    if p.closed or not name or p:field("ref") then
      return
    end
    use(p, { name = name, kind = "branch" }, true)
    p.data.default = gg.branches.get({ host = p.ctx.host, project = p.ctx.project, name = name })
    p.data.default:on_done(function(b)
      if b and not p.closed and p:field("ref") == name then
        p:set_field_note("ref", ref_picker.note(refs.from_branch(b)))
      end
    end)
  end)
end

-- `name` when GitLab has that branch, else the default branch
local function use_if_pushed(p, name)
  p.data.branch = gg.branches.get({ host = p.ctx.host, project = p.ctx.project, name = name })
  p.data.branch:on_done(function(b)
    if p.closed or p:field("ref") then
      return
    end
    if b then
      use(p, refs.from_branch(b), true)
    else
      use_default(p)
    end
  end)
end

---@type gg.ui.CreateDef
return {
  kind = "pipeline",
  tuning = TUNING,
  accent = "GitlabCreatePipeline",
  icon = "▶",
  label = "Run pipeline",
  entity = "Variables · 0",
  title = { readonly = true },
  fields = {
    {
      id = "ref",
      keymap = "create_source",
      label = "Branch or tag",
      icon = "⎇",
      hl = "GitlabBranchSource",
      empty = "pick a branch or tag",
      pick = function(p)
        refs.pick(p, "ref", {
          title = "Branch or tag",
          tags = true,
          on_pick = function(item)
            use(p, item, false)
          end,
        })
      end,
    },
  },
  body = { filetype = "gg_ui_variables" },
  submit_label = "Run",
  busy_label = "running…",
  api_fields = { ref = "field_ref" },
  changed = { "pipeline" },
  hints = function(p)
    return {
      { key = p:key("add_variable"), desc = "Add" },
      { key = "dd", desc = "Remove" },
      { key = p:key("toggle_variable_type"), desc = "Var ⇄ file" },
      { key = p:key("create_cancel"), desc = "Cancel" },
    }
  end,
  setup = function(p)
    p.data.editor = variables_view.attach(p)
    p:set_title("Run pipeline")
    if p.preset.ref then
      use_if_pushed(p, p.preset.ref)
    else
      p.data.current = project.current_branch(p.preset.cwd)
      p.data.current:on_done(function(name)
        if p.closed then
          return
        end
        if name then
          use_if_pushed(p, name)
        else
          use_default(p)
        end
      end)
    end
    p:focus("body")
  end,
  validate = function(p, v)
    if not v.fields.ref then
      return "Pick a branch or tag", "field_ref"
    end
    local _, problems = variables.parse(v.lines)
    if #problems > 0 then
      p:diagnose_body(vim.tbl_map(function(pr)
        return { lnum = pr.lnum - 1, col = pr.col, end_col = pr.end_col, message = pr.message }
      end, problems))
      return #problems == 1 and ("Line %d: %s"):format(problems[1].lnum, problems[1].message) or ("%d variables need fixing"):format(#problems)
    end
  end,
  submit = function(p, v)
    local entries = variables.parse(v.lines)
    return gg.pipelines.create({
      host = p.ctx.host,
      project = p.ctx.project,
      ref = v.fields.ref,
      variables = variables.payload(entries, p.data.editor:line_types()),
    })
  end,
  show = function(ctx, pipeline)
    require("gg.ui.detail").pipeline(ctx, pipeline)
  end,
}
