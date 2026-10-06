-- TESTS/testing/timeout_one_case_spec.lua -- one hung file is ONE timeout case: the persistent timeout error of the
-- file deadline also hits the rest of the describe body, and that must not become a second (synthetic
-- `<describe body>`) timeout case.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/child_support.lua")
  local inproc = require("testing.run.inproc")

  local root = S.new_root()
  local file = S.project(root, {
    ["TESTS/hang_spec.lua"] = [[
describe("hang", function()
  it("spawns and blocks", function()
    while true do end
  end)
  local s = 0
  for i = 1, 3000000 do
    s = s + i
  end
end)
]],
  }, { "TESTS/hang_spec.lua" }, "busted")[1]

  local rep = inproc.run({ root = root, files = { file }, timeouts = { file_ms = 300 } })
  local ids, statuses = {}, {}
  for _, c in ipairs(rep.result.cases) do
    ids[#ids + 1] = c.id
    statuses[#statuses + 1] = c.status
  end
  eq(statuses, { "timeout" }, "one hung file: one timeout case (" .. table.concat(ids, ", ") .. ")")
  eq(
    rep.result.cases[1].id,
    "TESTS/hang_spec.lua::hang::spawns and blocks",
    "the real case carries it"
  )
  S.cleanup()
end
