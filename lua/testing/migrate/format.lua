---@module 'testing.migrate.format'
---@brief Formats the Lua files the migration creates with the target repository's own `stylua.toml`.
---@description
--- The templates are written for the testing.nvim style (width 100, two spaces). A repository that
--- checks `stylua --check .` with another configuration (`column_width = 130`, tabs) would turn red on
--- the files the migration created, so `M.lua(src, rel, root, opts)` runs `stylua` on the new text:
---
---   stylua --config-path <root>/stylua.toml --stdin-filepath <root>/<rel> -     (cwd = root, text on stdin)
---
--- No shell is involved (argv list). Nothing is written by it; the formatted text goes into the plan.
--- A missing `stylua` (or one that fails) is never an error of the migration: the text stays as it was
--- rendered and the second return value says what the person has to do.
---
--- `opts.exe` (`false` = pretend it is not installed) and `opts.run` (`fun(argv, stdin, cwd)` returning
--- `{ code, stdout, stderr }`) are seams for specs.

local text = require("testing.migrate.text")

local uv = vim.uv or vim.loop

local M = {}

---@class Testing.Migrate.FormatOpts
---@field exe? string|false Executable name (default `stylua`); `false`: not installed.
---@field run? fun(argv: string[], stdin: string, cwd: string): { code: integer, stdout?: string, stderr?: string }

---The configuration file stylua would pick in `root`.
---@param root string
---@return string|nil path
function M.config_of(root)
  for _, name in ipairs({ "stylua.toml", ".stylua.toml" }) do
    local st = uv.fs_stat(root .. "/" .. name)
    if st and st.type == "file" then
      return root .. "/" .. name
    end
  end
end

---`column_width` of a stylua configuration, read as text (for the hint only).
---@param path string
---@return integer|nil
local function width_of(path)
  local src = text.read(path)
  local n = src and src:match("column_width%s*=%s*(%d+)")
  return n and tonumber(n) or nil
end

---@param argv string[]
---@param stdin string
---@param cwd string
---@return { code: integer, stdout?: string, stderr?: string }
local function default_run(argv, stdin, cwd)
  local ok, res = pcall(function()
    return vim.system(argv, { stdin = stdin, cwd = cwd, text = true, timeout = 20000 }):wait()
  end)
  if not ok then
    return { code = -1, stderr = tostring(res) }
  end
  return { code = res.code, stdout = res.stdout, stderr = res.stderr }
end

---Format `src` (the text of `rel` below `root`) the way the repository's stylua configuration wants.
---@param src string
---@param rel string Project-relative path of the file the text is for.
---@param root string
---@param opts? Testing.Migrate.FormatOpts
---@return string formatted `src` itself when nothing could be done.
---@return string|nil hint What the person has to do (stylua missing or failed); nil when all is well or there is no configuration.
function M.lua(src, rel, root, opts)
  opts = opts or {}
  local cfg = M.config_of(root)
  if not cfg then
    return src, nil
  end
  local exe = opts.exe
  if exe == nil then
    exe = "stylua"
  end
  if exe == false or (opts.run == nil and vim.fn.executable(exe) ~= 1) then
    local width = width_of(cfg)
    return src,
      ("stylua is not on PATH: %s is written in the template's style (column_width 100, two spaces) and was NOT formatted for %s%s; run `stylua %s` before committing"):format(
        text.show(rel, 100),
        text.show(vim.fs.basename(cfg), 40),
        width and (" (column_width " .. width .. ")") or "",
        text.show(rel, 100)
      )
  end
  local argv = { exe, "--config-path", cfg, "--stdin-filepath", root .. "/" .. rel, "-" }
  local res = (opts.run or default_run)(argv, src, root)
  local out = res.stdout
  if res.code ~= 0 or type(out) ~= "string" or out == "" or not loadstring(out) then
    local why = tostring(res.stderr or ("exit code " .. tostring(res.code))):gsub("%s+$", "")
    return src,
      ("stylua could not format %s (%s): it is written in the template's style, run `stylua %s` before committing"):format(
        text.show(rel, 100),
        text.show(why, 160),
        text.show(rel, 100)
      )
  end
  return out, nil
end

return M
