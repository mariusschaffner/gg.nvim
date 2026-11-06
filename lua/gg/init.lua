--- gg.nvim: a standalone, UI-free GitLab API layer for Neovim.
---
--- This module is the only stable surface for consumers. It only re-exports.
---@class gg
local M = {}

M.issues = require("gg.resources.issues")
M.labels = require("gg.resources.labels")
M.merge_requests = require("gg.resources.merge_requests")
M.milestones = require("gg.resources.milestones")
M.mr_changes = require("gg.resources.mr_changes")
M.mr_checks = require("gg.resources.mr_checks")
M.branches = require("gg.resources.branches")
M.users = require("gg.resources.users")
M.work_items = require("gg.resources.work_items")

return M
