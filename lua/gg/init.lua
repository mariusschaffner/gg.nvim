--- gg.nvim: a standalone, UI-free GitLab API layer for Neovim.
---
--- This module is the only stable surface for consumers. It only re-exports.
---@class gg
local M = {}

M.issues = require("gg.resources.issues")

return M
