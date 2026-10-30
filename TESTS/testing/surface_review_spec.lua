-- TESTS/testing/surface_review_spec.lua -- findings of the review of the surface code (REVIEW gate, binding-coverage-engine):
-- every module of lua/testing/surface is named where the modules are listed (CMT-01: the header of testing.surface,
-- its README, docs/SURFACE.md), and `--out` that cannot be written says why (the reason `atomic_write` returns).

---@diagnostic disable: need-check-nil, missing-fields

return function(H)
  local ok = H.ok
  local self_dir = require("testing.deps").self_dir()
  local function slurp(rel)
    local f = assert(io.open(self_dir .. "/" .. rel, "rb"))
    local text = f:read("*a")
    f:close()
    return text
  end

  -- ------------------------------------------------------------------ CMT-01: the module lists follow the directory
  local header = {}
  for _, line in ipairs(vim.split(slurp("lua/testing/surface/init.lua"), "\r?\n")) do
    if not line:match("^%-%-%-") then
      break
    end
    header[#header + 1] = line
  end
  local header_text = table.concat(header, "\n")
  local readme = slurp("lua/testing/surface/README.md")
  local doc = slurp("docs/SURFACE.md")
  local seen = 0
  for name, kind in vim.fs.dir(self_dir .. "/lua/testing/surface") do
    local mod = kind == "file" and name:match("^(.+)%.lua$") or nil
    if mod and mod ~= "init" then
      seen = seen + 1
      ok(
        header_text:find("`" .. mod .. "`", 1, true) ~= nil,
        ("the header of testing.surface names the module `%s`"):format(mod)
      )
      ok(
        readme:find("`testing.surface." .. mod .. "`", 1, true) ~= nil,
        ("lua/testing/surface/README.md lists testing.surface.%s"):format(mod)
      )
      ok(
        doc:find("`testing.surface." .. mod .. "`", 1, true) ~= nil,
        ("docs/SURFACE.md lists testing.surface.%s"):format(mod)
      )
    end
  end
  ok(seen >= 8, "the directory was read, saw " .. seen .. " modules")

  -- ------------------------------------------------------------------ --out that cannot be written says why
  local surface = require("testing.surface")
  local tmp = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(tmp, "p")
  local blocker = tmp .. "/a_file"
  vim.fn.writefile({ "x" }, blocker)
  local services = {
    cwd = tmp,
    config = { plugin = "fx", coverage = {}, deps = {} },
    collect = function()
      return {
        version = 1,
        plugin = "fx",
        root = tmp,
        notes = {},
        counts = { command = 1 },
        entries = { { id = "command:Open", kind = "command", name = "Open" } },
      }
    end,
  }
  local out = blocker .. "/out.txt"
  local code, text = surface.main({ "--out", out }, services)
  vim.fn.delete(tmp, "rf")
  H.eq(code, 3, "--out below a file: an infrastructure error")
  local reason = text:match("testing surface: cannot write " .. vim.pesc(out) .. ": ([^\n]*)")
  ok(
    reason ~= nil and reason ~= "" and reason ~= "nil",
    "--out: the reason is named, got " .. vim.inspect(reason)
  )
end
