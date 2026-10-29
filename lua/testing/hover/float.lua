---@module 'testing.hover.float'
---@brief The fallback without hover.nvim: the same text in a plain float next to the cursor.
---@description
--- `open(content)` shows a `Testing.Hover.Content` through `lib.nvim.window.make_scratch` (an unlisted scratch
--- buffer, read-only, plain text, no filetype so nothing is highlighted or evaluated) and closes it again as soon
--- as the cursor moves, insert mode starts or the window is left. It is not focused: the float is a glance.

local M = {}

---@param content Testing.Hover.Content
---@param limits? Testing.Hover.Limits
---@return integer|nil winid
function M.open(content, limits)
  local fitted = require("testing.hover.format").fit(content, limits)
  local winid = require("lib.nvim.window.make_scratch")({
    lines = fitted.lines,
    relative = "cursor",
    row = 1,
    col = 0,
    title = fitted.title,
    enter = false,
    zindex = 60,
  })
  if not winid then
    return nil
  end
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave" }, {
    group = vim.api.nvim_create_augroup("TestingHoverFloat", { clear = false }),
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(winid) then
        pcall(vim.api.nvim_win_close, winid, true)
      end
    end,
  })
  return winid
end

return M
