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
  -- merge requests
  { "GitlabDraft", "Comment" },
  { "GitlabBranchSource", "Statement" },
  { "GitlabBranchTarget", "Comment" },
  { "GitlabPipelineSuccess", "DiagnosticOk" },
  { "GitlabPipelineFailed", "DiagnosticError" },
  { "GitlabPipelineRunning", "DiagnosticWarn" },
  { "GitlabPipelinePending", "Comment" },
  { "GitlabPipelineManual", "Comment" },
  { "GitlabPipelineCanceled", "Comment" },
  { "GitlabPipelineSkipped", "NonText" },
  -- the same green and red as the pipeline icons; foreground only, so the
  -- bar's "━" cells are drawn in that colour (Diff* groups carry a background)
  { "GitlabDiffAdd", "GitlabPipelineSuccess" },
  { "GitlabDiffDelete", "GitlabPipelineFailed" },
  -- pipelines
  { "GitlabRefDefault", "Special" },
  { "GitlabRefTag", "Constant" },
  { "GitlabSha", "DiagnosticWarn" },
  { "GitlabPipelineSource", "Comment" },
  { "GitlabPipelineSourceSchedule", "DiagnosticWarn" },
  -- detail views; dimmed text is plain gray (Comment's colour, never italic)
  { "GitlabDetailBorder", "GitlabTableBorder" },
  -- while something is edited: its box border and its sidebar label
  { "GitlabDetailBorderEditing", "DiagnosticWarn" },
  { "GitlabDetailLabelEditing", "DiagnosticWarn" },
  { "GitlabFieldEdit", "NormalFloat" },
  { "GitlabEditPlaceholder", "GitlabDetailDim" },
  { "GitlabDetailTabActive", "GitlabPickerTitle" }, -- like the picker's " Table " title
  { "GitlabDetailBreadcrumb", "GitlabDetailDim" },
  { "GitlabDetailRef", "DiagnosticWarn" },
  { "GitlabDetailMeta", "GitlabDetailDim" },
  { "GitlabDetailLabel", "GitlabDetailDim" },
  { "GitlabDetailMuted", "GitlabDetailDim" },
  { "GitlabDetailDivider", "NonText" },
  { "GitlabDetailAccent", "Function" },
  { "GitlabDetailHashtag", "DiagnosticWarn" },
  { "GitlabDetailDate", "Constant" },
  { "GitlabDetailError", "DiagnosticError" },
  { "GitlabDetailPositive", "DiagnosticOk" },
  { "GitlabDetailTab", "GitlabDetailDim" },
  { "GitlabMilestoneRef", "Special" },
  { "GitlabTaskOpen", "DiagnosticWarn" },
  { "GitlabTaskDone", "DiagnosticOk" },
  { "GitlabTaskDoneText", "GitlabDetailDim" },
  { "GitlabProgressDoing", "Constant" },
  { "GitlabChipFallback", "Visual" },
  { "GitlabCard", "CursorLine" },
  { "GitlabStateMerged", "Constant" },
  -- the activity timeline
  { "GitlabTimelineDay", "Title" },
  { "GitlabTimelineRule", "NonText" },
  { "GitlabTimelineTime", "GitlabDetailDim" },
  { "GitlabTimelineIcon", "GitlabDetailDim" },
  { "GitlabTimelineVerb", "GitlabDetailDim" },
  { "GitlabTimelineRef", "Special" },
  { "GitlabTimelineGuide", "NonText" },
  { "GitlabTimelineMore", "GitlabDetailDim" },
  { "GitlabCommentBg", "CursorLine" },
  { "GitlabCommentReplyBg", "CursorLine" },
  { "GitlabCommentBar", "Function" },
  { "GitlabBadgeYou", "DiagnosticInfo" },
  { "GitlabBadgeResolved", "DiagnosticOk" },
  { "GitlabBadgeUnresolved", "DiagnosticWarn" },
  { "GitlabBadgeContext", "Special" },
  { "GitlabReaction", "GitlabDetailDim" },
  -- strips (merge readiness, milestone dates)
  { "GitlabStripDone", "DiagnosticOk" },
  { "GitlabStripPending", "DiagnosticWarn" },
  { "GitlabStripFailed", "DiagnosticError" },
  { "GitlabStripRule", "NonText" },
  { "GitlabStripMuted", "GitlabDetailDim" },
  { "GitlabStripMerged", "Constant" },
  { "GitlabTimelineBar", "Special" },
  { "GitlabTimelineOverdue", "DiagnosticError" },
  -- commits
  { "GitlabCommitFeat", "DiagnosticOk" },
  { "GitlabCommitFix", "DiagnosticWarn" },
  { "GitlabCommitTest", "DiagnosticWarn" },
  { "GitlabCommitMerge", "Constant" },
  { "GitlabCommitDocs", "Function" },
  { "GitlabCommitRefactor", "Special" },
  { "GitlabCommitRevert", "DiagnosticError" },
  { "GitlabCommitOther", "GitlabDetailDim" },
  -- pipeline graph and job log
  { "GitlabGraphBorder", "NonText" },
  { "GitlabGraphSelected", "Function" },
  { "GitlabGraphMore", "GitlabDetailDim" },
  { "GitlabGraphStage", "Title" },
  { "GitlabLogError", "DiagnosticError" },
  { "GitlabLogWarn", "DiagnosticWarn" },
  { "GitlabLogInfo", "Function" },
  { "GitlabLogOk", "DiagnosticOk" },
  { "GitlabLogSection", "Function" },
  { "GitlabLogErrorLine", "DiffDelete" },
  { "GitlabLogWarnLine", "DiffChange" },
  { "GitlabLogTail", "Special" },
  { "GitlabBadgeFollow", "DiagnosticOk" },
  { "GitlabAnsiBlack", "GitlabDetailDim" },
  { "GitlabAnsiRed", "DiagnosticError" },
  { "GitlabAnsiGreen", "DiagnosticOk" },
  { "GitlabAnsiYellow", "DiagnosticWarn" },
  { "GitlabAnsiBlue", "Function" },
  { "GitlabAnsiMagenta", "Constant" },
  { "GitlabAnsiCyan", "Special" },
  { "GitlabAnsiWhite", "Normal" },
  -- one colour per user (a stable hash picks the group), see gg.ui.lib.user_hl
  { "GitlabUser1", "Function" },
  { "GitlabUser2", "Special" },
  { "GitlabUser3", "Constant" },
  { "GitlabUser4", "Statement" },
  { "GitlabUser5", "String" },
  { "GitlabUser6", "Type" },
  { "GitlabUser7", "Identifier" },
  { "GitlabUser8", "PreProc" },
}
--- Pills: { name, group whose text colour becomes the background }.
M.PILLS = {
  { "GitlabPillOpened", "DiagnosticOk" },
  { "GitlabPillClosed", "Constant" },
  { "GitlabPillMerged", "Constant" },
  { "GitlabPillDraft", "Comment" },
  { "GitlabPillDeclined", "DiagnosticError" },
  { "GitlabPillActive", "DiagnosticOk" },
  { "GitlabPillUpcoming", "Function" },
  { "GitlabPillOverdue", "DiagnosticError" },
  { "GitlabPillRunning", "Special" },
  { "GitlabPillPending", "DiagnosticWarn" },
  { "GitlabPillPassed", "DiagnosticOk" },
  { "GitlabPillFailed", "DiagnosticError" },
  { "GitlabPillCanceled", "Comment" },
  { "GitlabPillManual", "DiagnosticWarn" },
  { "GitlabChipFeat", "DiagnosticOk" },
  { "GitlabChipFix", "DiagnosticWarn" },
  { "GitlabChipTest", "DiagnosticWarn" },
  { "GitlabChipMerge", "Constant" },
  { "GitlabChipDocs", "Function" },
  { "GitlabChipRefactor", "Special" },
  { "GitlabChipRevert", "DiagnosticError" },
  { "GitlabChipOther", "Comment" },
  { "GitlabCommentAvatar", "Function" },
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
  -- layered over a GitlabUserN group for the signed-in user
  vim.api.nvim_set_hl(0, "GitlabCurrentUser", { bold = true, default = true })
  -- detail views: plain gray for dimmed text, bright text and bold names
  vim.api.nvim_set_hl(0, "GitlabDetailDim", { fg = resolved("Comment").fg, default = true })
  -- what is not there yet: "write a new comment…", "+ link branch"
  vim.api.nvim_set_hl(0, "GitlabDetailPlaceholder", { fg = resolved("Comment").fg, italic = true, default = true })
  vim.api.nvim_set_hl(0, "GitlabDetailTitle", { fg = normal_fg, bold = true, default = true })
  vim.api.nvim_set_hl(0, "GitlabDetailValue", { fg = normal_fg, default = true })
  vim.api.nvim_set_hl(0, "GitlabTimelineActor", { fg = normal_fg, bold = true, default = true })
  vim.api.nvim_set_hl(0, "GitlabTimelineObject", { fg = normal_fg, default = true })
  vim.api.nvim_set_hl(0, "GitlabAnsiBold", { bold = true, default = true })
  -- pills and type chips: the colour as background (reverse video)
  for _, p in ipairs(M.PILLS) do
    vim.api.nvim_set_hl(0, p[1], { fg = resolved(p[2]).fg, reverse = true, bold = true, default = true })
  end
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

--- The chip group for a label colour ("#RRGGBB"): the colour as background
--- and black or white text, whichever reads better. Created on demand;
--- invalid colours fall back to `GitlabChipFallback`.
---@param color string|nil
---@return string
function M.chip(color)
  local hex = type(color) == "string" and color:match("^#(%x%x%x%x%x%x)$")
  if not hex then
    local short = type(color) == "string" and color:match("^#(%x%x%x)$")
    if not short then
      return "GitlabChipFallback"
    end
    hex = short:gsub("(%x)", "%1%1")
  end
  hex = hex:lower()
  local r, g, b = tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
  local luma = 0.299 * r + 0.587 * g + 0.114 * b
  local name = "GitlabChip_" .. hex
  vim.api.nvim_set_hl(0, name, { bg = "#" .. hex, fg = luma > 150 and "#000000" or "#ffffff", default = true })
  return name
end

return M
