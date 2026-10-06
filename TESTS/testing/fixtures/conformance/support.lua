-- TESTS/testing/fixtures/conformance/support.lua -- helpers of the conformance specs (not a spec itself).
--
-- `S.new_repo()` copies the conformant fixture plugin (`good/`, a plugin called `goodp`) into a fresh
-- temporary directory named `goodp.nvim`; a spec changes the copy to violate exactly one rule. The
-- copies are removed by `S.cleanup()`.

local S = {}

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
S.dir = vim.fs.dirname(vim.fs.normalize(here))
S.good = S.dir .. "/good"
---testing.nvim checkout.
S.repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(S.dir))))

---@type string[]
local made = {}

---@param path string
---@param text string
function S.write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---@param path string
---@return string|nil
function S.slurp(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

---@param src string
---@param dst string
local function copy_tree(src, dst)
  vim.fn.mkdir(dst, "p")
  for name, kind in vim.fs.dir(src) do
    if kind == "directory" then
      copy_tree(src .. "/" .. name, dst .. "/" .. name)
    elseif kind == "file" then
      S.write(dst .. "/" .. name, assert(S.slurp(src .. "/" .. name)))
    end
  end
end

---A copy of the conformant fixture plugin.
---@param name? string Directory name (default `goodp.nvim`).
---@return string root
function S.new_repo(name)
  local base = vim.fs.normalize(vim.fn.tempname()) .. "-conf"
  made[#made + 1] = base
  local root = base .. "/" .. (name or "goodp.nvim")
  copy_tree(S.good, root)
  return root
end

---Replace the first plain occurrence of `old` in a file of the repository.
---@param root string
---@param rel string
---@param old string
---@param new string
function S.patch(root, rel, old, new)
  local text = assert(S.slurp(root .. "/" .. rel), "cannot read " .. rel)
  local i, j = text:find(old, 1, true)
  assert(i, ("%s does not contain %q"):format(rel, old))
  S.write(root .. "/" .. rel, text:sub(1, i - 1) .. new .. text:sub(j + 1))
end

---@param root string
---@param rel string
function S.remove(root, rel)
  vim.fn.delete(root .. "/" .. rel, "rf")
end

---Remove every copy made so far.
function S.cleanup()
  for _, dir in ipairs(made) do
    pcall(vim.fn.delete, dir, "rf")
  end
  made = {}
end

---Run `body`, clean up whatever happened, re-raise a failure of the body.
---@param body fun()
function S.run(body)
  local ok, err = xpcall(body, debug.traceback)
  S.cleanup()
  if not ok then
    error(err, 0)
  end
end

---The result of check `id` in a report.
---@param report table
---@param id string
---@return table
function S.check(report, id)
  for _, r in ipairs(report.checks) do
    if r.id == id then
      return r
    end
  end
  error("the report has no check " .. id)
end

---Does a finding of check `id` contain `needle` (plain) in its message?
---@param report table
---@param id string
---@param needle string
---@return table|nil finding
function S.finding(report, id, needle)
  for _, f in ipairs(S.check(report, id).findings) do
    if f.message:find(needle, 1, true) then
      return f
    end
  end
  return nil
end

---All messages of a check, for a failure message.
---@param report table
---@param id string
---@return string
function S.messages(report, id)
  local out = {}
  for _, f in ipairs(S.check(report, id).findings) do
    out[#out + 1] = ("%s %s:%s %s"):format(f.level, f.file or "-", f.line or "-", f.message)
  end
  local r = S.check(report, id)
  return ("%s status=%s reason=%s findings=[%s]"):format(
    id,
    r.status,
    tostring(r.reason),
    table.concat(out, " || ")
  )
end

return S
