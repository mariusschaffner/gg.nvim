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
  { "GitlabPickerFooter", "Function" },
  { "GitlabPickerPrompt", "Function" },
  { "GitlabTab", "Comment" },
  { "GitlabTabActive", "PmenuSel" },
  { "GitlabColumnHeader", "Title" },
  { "GitlabSeparator", "WinSeparator" },
  { "GitlabMilestoneEdge", "WinSeparator" },
  { "GitlabMilestoneEdgeActive", "Function" },
  { "GitlabMilestoneName", "Special" },
  { "GitlabMilestoneTitle", "Bold" },
  { "GitlabDue", "Normal" },
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
  { "GitlabHintText", "GitlabPickerFooter" },
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
  -- hint keys ("[I]") are the footer colour in bold
  local key = vim.tbl_extend("force", resolved("GitlabPickerFooter"), { bold = true, default = true })
  key.link = nil
  vim.api.nvim_set_hl(0, "GitlabHintKey", key)
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
