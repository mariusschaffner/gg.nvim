--- New merge request: source and target branch, a title, a description.
---
--- Defaults: the source is the current git branch, the target the
--- project's default branch, the title `Merge <source> into <target>`. A
--- source branch named after an issue (`22-some-feature`) gives that
--- issue's title and `Closes #22` as the first description line. The merge
--- request is assigned to the signed-in user.
---
--- Before sending: the source branch must be on GitLab (else: offer to push
--- it), and an open merge request for it is offered instead of a second one.
local confirm = require("gg.ui.components.confirm")
local gg = require("gg")
local mr = require("gg.ui.create.mr")
local project = require("gg.ui.project")
local refs = require("gg.ui.create.refs")

local MEMBER = { title = "title", source = "field_source", target = "field_target" }

-- title and `Closes #N` for the current branches, while the user has not
-- written their own
local function refresh(p)
  local source, target = p:field("source"), p:field("target")
  local function apply(issue_title)
    if p.closed then
      return
    end
    local current = p:title()
    if current == "" or current == p.data.auto_title or mr.is_generated(current) then
      local title = mr.title(source, target, issue_title)
      p.data.auto_title = title
      if title ~= current then
        p:set_title(title)
      end
    end
  end
  local iid = mr.issue_iid(source)
  if not iid then
    return apply(nil)
  end
  -- "Closes #N" leads the description while it is empty (or still ours)
  local lines = p:body_lines()
  local first = lines[1] or ""
  if (#lines == 1 and first == "") or first == p.data.closes then
    p.data.closes = mr.closes(iid)
    lines[1] = p.data.closes
    p:set_body(lines)
  end
  if p.data.issue_iid == iid then
    return apply(p.data.issue_title)
  end
  p.data.issue_iid, p.data.issue_title = iid, nil
  apply(nil)
  p.data.issue = gg.issues.get({ host = p.ctx.host, project = p.ctx.project, iid = iid })
  p.data.issue:on_done(function(issue)
    -- no such issue: the branch just starts with a number
    if issue and p.data.issue_iid == iid and mr.issue_iid(p:field("source")) == iid then
      p.data.issue_title = issue.title
      apply(issue.title)
    end
  end)
end

local function pick(p, field)
  refs.pick(p, field.id, {
    title = field.id == "source" and "Source branch" or "Target branch",
    on_pick = function(item)
      p:set_field(field.id, item.name)
      refresh(p)
    end,
  })
end

-- the source branch is on GitLab: `yes()`; else offer to push it
local function ensure_pushed(p, source, yes, stop)
  gg.branches.get({ host = p.ctx.host, project = p.ctx.project, name = source }):on_done(function(_, err)
    if p.closed then
      return
    end
    if not err then
      return yes()
    end
    if err.kind ~= "not_found" then
      return stop(err.message, MEMBER.source)
    end
    confirm.ask(("Branch %s is not on GitLab. Push it (git push -u origin %s)?"):format(source, source), function()
      vim.notify(("gg.ui: Pushing %s…"):format(source), vim.log.levels.INFO)
      project.push(source, p.preset.cwd):on_done(function(_, perr)
        if p.closed then
          return
        end
        if perr then
          return stop(perr.message, MEMBER.source)
        end
        yes()
      end)
    end, function()
      if not p.closed then
        stop(("Branch %s is not on GitLab"):format(source), MEMBER.source)
      end
    end)
  end)
end

-- no open merge request for the source branch: `no()`; else offer to open it
local function ensure_new(p, source, no, stop)
  local args = { host = p.ctx.host, project = p.ctx.project, source_branch = source, state = "opened" }
  gg.merge_requests.list(args, { per_page = 1 }):on_done(function(page, err)
    if p.closed then
      return
    end
    if err then
      return stop(err.message)
    end
    local existing = page.items[1]
    if not existing then
      return no()
    end
    confirm.ask(("!%d already exists for %s. Open it instead?"):format(existing.iid, source), function()
      if p.closed then
        return
      end
      local ctx = p.ctx
      ctx.stack:pop()
      require("gg.ui.detail").merge_request(ctx, existing)
    end, function()
      if not p.closed then
        stop(("!%d already exists for %s"):format(existing.iid, source), MEMBER.source)
      end
    end)
  end)
end

---@type gg.ui.CreateDef
return {
  kind = "merge_request",
  accent = "GitlabCreateMR",
  icon = "＋",
  label = "New merge request",
  entity = "Merge Request",
  title = { placeholder = "title" },
  fields = {
    { id = "source", keymap = "create_source", label = "Source", icon = "⎇", hl = "GitlabBranchSource", empty = "pick a branch", pick = pick },
    { id = "target", keymap = "create_target", label = "Target", icon = "⎇", hl = "GitlabBranchTarget", empty = "pick a branch", pick = pick },
  },
  body = { filetype = "markdown" },
  submit_label = "Create",
  busy_label = "creating…",
  api_fields = { title = "title", description = "body", source_branch = MEMBER.source, target_branch = MEMBER.target },
  changed = { "merge_request", "issue" },
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
    -- the defaults that need git and GitLab; the cursor is placed once they are in
    local pending = 2
    local function settled()
      pending = pending - 1
      if p.closed then
        return
      end
      refresh(p)
      if pending == 0 and not p:dirty() then
        p:start()
      end
    end
    local function source(name)
      if name and not p.closed and not p:field("source") then
        p:set_field("source", name, nil, { prefill = true })
      end
      settled()
    end
    local function target(name)
      if name and not p.closed and not p:field("target") then
        p:set_field("target", name, nil, { prefill = true })
      end
      settled()
    end
    if pre.source_branch then
      source(pre.source_branch)
    else
      p.data.branch = project.current_branch(pre.cwd)
      p.data.branch:on_done(function(name)
        source(name or nil)
      end)
    end
    if pre.target_branch then
      target(pre.target_branch)
    else
      p.data.project = gg.projects.get({ host = p.ctx.host, project = p.ctx.project })
      p.data.project:on_done(function(proj)
        target(proj and proj.default_branch or nil)
      end)
    end
    p.data.me = gg.users.current({ host = p.ctx.host })
    p.data.me:on_done(function(user)
      p.data.user = user
    end)
  end,
  validate = function(_, v)
    local msg, where = mr.validate({ title = v.title, source = v.fields.source, target = v.fields.target })
    return msg, where and MEMBER[where] or nil
  end,
  precheck = function(p, v, go, stop)
    ensure_pushed(p, v.fields.source, function()
      ensure_new(p, v.fields.source, go, stop)
    end, stop)
  end,
  submit = function(p, v)
    return gg.merge_requests.create({
      host = p.ctx.host,
      project = p.ctx.project,
      source_branch = v.fields.source,
      target_branch = v.fields.target,
      title = v.title,
      description = v.description ~= "" and v.description or nil,
      assignee_ids = p.data.user and { p.data.user.id } or nil,
    })
  end,
  show = function(ctx, merge_request)
    require("gg.ui.detail").merge_request(ctx, merge_request)
  end,
}
