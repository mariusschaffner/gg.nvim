-- Test entry point used by `make test`.
-- mini.test does not quit when there are no cases, so handle that here and
-- always exit with a status code: 0 when every case passes, 1 otherwise.
local M = {}

---@param file string|nil run a single file instead of the whole suite
function M.run(file)
  local collect = nil
  if file and file ~= "" then
    collect = { find_files = function() return { file } end }
  end
  local ok, cases = pcall(MiniTest.collect, collect)
  if not ok then
    io.stdout:write("Failed to collect test cases: " .. tostring(cases) .. "\n")
    vim.cmd("cquit 1")
    return
  end
  if #cases == 0 then
    io.stdout:write("Total number of cases: 0\nTotal number of groups: 0\n\nNo test cases found.\n")
    vim.cmd("qall!")
    return
  end
  MiniTest.execute(cases)
end

return M
