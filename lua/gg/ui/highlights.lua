--- Highlight groups of the UI. Every group is defined with `default = true`
--- and linked to a standard group, so colourschemes and users can override it.
--- Label groups (`GitlabLabel_<hex>`) are created on demand from GitLab's
--- label colours.
local M = {}

--- { name, link } in definition order.
M.LINKS = {
  { "GitlabPickerBorder", "FloatBorder" },
  { "GitlabPickerBorderActive", "Function" },
  { "GitlabPickerTitle", "FloatTitle" },
  { "GitlabPickerFooter", "Comment" },
  { "GitlabPickerPrompt", "Function" },
  { "GitlabTab", "Comment" },
  { "GitlabTabActive", "PmenuSel" },
  { "GitlabColumnHeader", "Title" },
  { "GitlabTableBorder", "NonText" },
  { "GitlabSeparator", "NonText" },
  { "GitlabMilestoneEdge", "NonText" },
  { "GitlabMilestoneEdgeActive", "Function" },
  { "GitlabMilestoneName", "Special" },
  { "GitlabMilestoneTitle", "Bold" },
  { "GitlabDueSoon", "DiagnosticWarn" },
  { "GitlabDueOverdue", "DiagnosticError" },
  { "GitlabProgressDone", "DiagnosticOk" },
  { "GitlabProgressTodo", "NonText" },
  { "GitlabProgressText", "Comment" },
  { "GitlabIid", "Comment" },
  { "GitlabUnassigned", "NonText" },
  { "GitlabEmpty", "NonText" },
  { "GitlabStateOpened", "DiagnosticOk" },
  { "GitlabStateClosed", "Statement" },
  { "GitlabCursorMark", "Function" },
  { "GitlabCursorLine", "CursorLine" },
  { "GitlabLabelFallback", "Comment" },
}

local function resolved(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return ok and hl or {}
end

--- Define (or re-define after a colourscheme change) every UI group.
function M.define()
  -- `Bold` is not a standard group; create it only when missing
  vim.api.nvim_set_hl(0, "Bold", { bold = true, default = true })
  for _, pair in ipairs(M.LINKS) do
    vim.api.nvim_set_hl(0, pair[1], { link = pair[2], default = true })
  end
  -- Normal's text colour only: its background would cover the row highlight
  local normal_fg = resolved("Normal").fg
  vim.api.nvim_set_hl(0, "GitlabIssueTitle", { fg = normal_fg, default = true })
  vim.api.nvim_set_hl(0, "GitlabDue", { fg = normal_fg, default = true })
  -- hints: the key ("[I]") in blue and bold, the description in plain gray
  local key = { fg = resolved("Function").fg, bold = true, default = true }
  vim.api.nvim_set_hl(0, "GitlabHintKey", key)
  vim.api.nvim_set_hl(0, "GitlabHintText", { fg = resolved("Comment").fg, default = true })
  -- the table hides the cursor; blend = 100 makes it invisible
  vim.api.nvim_set_hl(0, "GitlabHiddenCursor", { blend = 100, nocombine = true, default = true })
end

--- Define the groups now and again on every `ColorScheme`.
function M.setup()
  M.define()
  local group = vim.api.nvim_create_augroup("gg.ui.highlights", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      M.define()
    end,
  })
end

--- The highlight group for a label colour ("#RRGGBB"), created on demand.
--- Invalid or missing colours fall back to `GitlabLabelFallback`.
---@param color string|nil
---@return string
function M.label(color)
  local hex = type(color) == "string" and color:match("^#(%x%x%x%x%x%x)$")
  if not hex then
    local short = type(color) == "string" and color:match("^#(%x%x%x)$")
    if not short then
      return "GitlabLabelFallback"
    end
    hex = short:gsub("(%x)", "%1%1")
  end
  hex = hex:lower()
  local name = "GitlabLabel_" .. hex
  vim.api.nvim_set_hl(0, name, { fg = "#" .. hex, default = true })
  return name
end

return M
