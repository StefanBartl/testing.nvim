---@module 'testing.hover.float'
---@brief The fallback without hover.nvim: the same text in a plain float next to the cursor.
---@description
--- `open(content, limits)` shows a `Testing.Hover.Content` through `lib.nvim.window.make_scratch` (an unlisted
--- scratch buffer, read-only, plain text, no filetype so nothing is highlighted or evaluated) and closes it again
--- as soon as the cursor moves, insert mode starts or the window is left. It is not focused: the float is a glance.
--- The first line is coloured with the content's `highlight` group (the verdict: red, outdated, not run).

local M = {}

---The highlight groups of `testing.hover.format` and what each one links to when nobody defined it. `HoverError`
---is also hover.nvim's own group (it defines it the same way, `default = true`); `TestingHoverWarn` exists only
---here, because hover.nvim has no warning group.
---@type table<string, string>
local LINKS = {
  HoverError = "DiagnosticError",
  TestingHoverWarn = "DiagnosticWarn",
}

---Define the default link of a highlight group of the hover, unless a colorscheme or the user defined it already.
---@param name any
---@return boolean known  The group is one the hover uses.
function M.ensure_highlight(name)
  local link = type(name) == "string" and LINKS[name] or nil
  if not link then
    return false
  end
  pcall(vim.api.nvim_set_hl, 0, name, { link = link, default = true })
  return true
end

---@param content Testing.Hover.Content
---@param limits? Testing.Hover.Limits  The configured size; without it the defaults (80 x 20).
---@return integer|nil winid
function M.open(content, limits)
  local fitted = require("testing.hover.format").fit(content, limits)
  local winid, bufnr = require("lib.nvim.window.make_scratch")({
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
  if bufnr and #fitted.lines > 0 and M.ensure_highlight(fitted.highlight) then
    pcall(
      vim.api.nvim_buf_set_extmark,
      bufnr,
      vim.api.nvim_create_namespace("testing_hover"),
      0,
      0,
      {
        end_row = 1,
        hl_group = fitted.highlight,
        hl_eol = true,
      }
    )
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
