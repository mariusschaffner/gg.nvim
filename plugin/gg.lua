-- :Gitlab [project] opens the issues picker (gg.ui). The API layer itself
-- defines no commands; this file only registers the UI entry point and
-- loads nothing until the command runs.
if vim.g.loaded_gg_ui then
  return
end
vim.g.loaded_gg_ui = true

vim.api.nvim_create_user_command("Gitlab", function(cmd)
  require("gg.ui").open({ project = cmd.args ~= "" and cmd.args or nil })
end, {
  nargs = "?",
  desc = "GitLab issues picker: [host/]group/project, default: the git remote",
})
