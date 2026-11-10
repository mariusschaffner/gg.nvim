--- gg.nvim: a standalone, UI-free GitLab API layer for Neovim.
---
--- This module is the only stable surface for consumers. It only re-exports.
--- See `:help gg`.
local config = require("gg.config")

---@class gg
local M = {}

--- Configure gg. Returns `true`, or `false, err` (the previous config stays).
M.setup = config.setup

--- Read the effective configuration.
M.config = {
  get = config.get,
  host = config.host,
  hosts = config.hosts,
}

--- Tasks: `run`, `all`, `new`, `resolved`, `failed`, `is_task`.
M.task = require("gg.core.task")

--- Errors: `is`, `is_cancelled`, `new`, `wrap`, `KINDS`.
M.errors = require("gg.core.errors")

--- Remote URLs, web URLs and short references: `parse`, `parse_web_url`, `parse_ref`.
M.context = require("gg.context")

--- Test support for consumers: a backend that replays fixtures.
M.testing = {
  fake_backend = require("gg.transport.backends.fake"),
}

-- resources
M.artifacts = require("gg.resources.artifacts")
M.branches = require("gg.resources.branches")
M.issues = require("gg.resources.issues")
M.jobs = require("gg.resources.jobs")
M.labels = require("gg.resources.labels")
M.merge_requests = require("gg.resources.merge_requests")
M.milestones = require("gg.resources.milestones")
M.mr_changes = require("gg.resources.mr_changes")
M.mr_checks = require("gg.resources.mr_checks")
M.notes = require("gg.resources.notes")
M.pipelines = require("gg.resources.pipelines")
M.projects = require("gg.resources.projects")
M.registry = require("gg.resources.registry")
M.reviews = require("gg.resources.reviews")
M.tags = require("gg.resources.tags")
M.todos = require("gg.resources.todos")
M.users = require("gg.resources.users")
M.work_items = require("gg.resources.work_items")

return M
