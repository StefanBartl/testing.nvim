---@diagnostic disable: undefined-field, need-check-nil
-- TESTS/testing/fixtures/guard/boot.lua -- shared bootstrap of the guard scenario scripts (not a spec,
-- not a fixture on its own). A scenario script runs in a REAL child editor:
--
--   nvim -n -i NONE --headless -u NONE -l <script>.fixture.lua <repo> <lib> [scenario]
--
-- It registers scenarios with `B.case(name, spec)`; `B.finish()` runs them one after the other, each
-- with a fresh `testing.guard` install/uninstall, and prints ONE line `GUARD-RESULT:<json>` that the
-- spec parses. Every guard has RED scenarios (the guard must trigger) and GREEN controls (the
-- guard must stay quiet).

local B = {}

B.repo = arg[1]
B.lib = arg[2]
B.only = arg[3] ~= "-" and arg[3] or nil

vim.opt.rtp:prepend(B.repo)
vim.opt.rtp:append(B.lib)

B.guard = require("testing.guard")

local cases = {}

---@class Testing.Guard.Scenario
---@field cfg? table Guard configuration (`testing.guard.install`).
---@field ctx? table Case context (`id`, `file`, `name`, `tags`).
---@field heavy? boolean Take the heavy (file-tree) snapshot.
---@field restore? boolean|string[] Soft isolation after the case.
---@field setup? fun(): any Runs before the install; its result is `env`.
---@field body fun(h: table, env: any): any The spec body, inside the case window.
---@field after? fun(h: table, res: table, env: any): any Runs after `end_case`; its result is `extra`.

---Register a scenario.
---@param name string
---@param spec Testing.Guard.Scenario
function B.case(name, spec)
  cases[#cases + 1] = { name = name, spec = spec }
end

---The two directories the spec made with `vim.fn.tempname()` and passed as arguments: `tmp` becomes
---the OS temp dir of this child (writes there are allowed), `outside` is a sibling that is not under it
---(a write there is a leak).
---@return { tmp: string, outside: string }
function B.sandbox()
  if B.sb then
    return B.sb
  end
  local tmp, outside = arg[4], arg[5]
  assert(tmp and outside, "usage: <script> <repo> <lib> <scenario|-> <tmp dir> <outside dir>")
  tmp, outside = vim.fs.normalize(tmp), vim.fs.normalize(outside)
  vim.fn.mkdir(tmp, "p")
  vim.fn.mkdir(outside, "p")
  vim.env.TMPDIR, vim.env.TMP, vim.env.TEMP = tmp, tmp, tmp
  B.sb = { tmp = tmp, outside = outside }
  return B.sb
end

---@param findings table[]
---@return table[]
local function brief(findings)
  local out = {}
  for _, f in ipairs(findings) do
    out[#out + 1] = {
      id = f.id,
      severity = f.severity,
      message = f.message,
      count = f.count,
      stack = f.stack ~= nil,
    }
  end
  return out
end

function B.finish()
  local results = {}
  for _, c in ipairs(cases) do
    if not B.only or B.only == c.name then
      local spec = c.spec
      local out = { name = c.name }
      local env = spec.setup and spec.setup() or nil
      local ok_install, h = pcall(B.guard.install, spec.cfg or {})
      if not ok_install then
        out.install_error = tostring(h)
      else
        h:begin_case(spec.ctx or { id = "fx::" .. c.name, file = "fx.lua" }, { heavy = spec.heavy })
        local ok, err = pcall(spec.body, h, env)
        if not ok then
          out.body_error = tostring(err)
        else
          out.value = err
        end
        local res = h:end_case({ restore = spec.restore })
        out.findings = brief(res.findings)
        out.effects = res.effects
        out.prompts = res.ledger:entries("prompts")
        out.restored = res.restored
        if spec.after then
          local ok2, extra = pcall(spec.after, h, res, env)
          if ok2 then
            out.extra = extra
          else
            out.extra = { after_error = tostring(extra) }
          end
        end
        out.collect = {
          findings = #h:collect().findings,
          effects = h:collect().effects,
          notes = h:collect().notes,
        }
        out.unrestored = h:uninstall()
      end
      results[#results + 1] = out
    end
  end
  io.stdout:write("\nGUARD-RESULT:" .. vim.json.encode(results) .. "\n")
  io.stdout:flush()
  os.exit(0)
end

return B
