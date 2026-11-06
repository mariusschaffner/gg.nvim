-- Minimal init for the headless test run (`make test`).
-- Puts the repository and the pinned mini.nvim checkout on the runtimepath.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
root = root:gsub("\\", "/")

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/deps/mini.nvim")
package.path = table.concat({ root .. "/?.lua", root .. "/?/init.lua", package.path }, ";")

vim.o.swapfile = false
vim.o.shadafile = "NONE"

require("mini.test").setup()
