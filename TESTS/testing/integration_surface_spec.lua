-- TESTS/testing/integration_surface_spec.lua -- the runner owns the surface tracking: with `surface = { track = true }`
-- in `.testing.lua` every case of the IR carries `surface.hit` (in a child editor per file AND in this process),
-- the project's minit does not call `track.hook_runner` any more, and `testing surface --from ir.json` joins the
-- IR with the surface. Without the key nothing is tracked, and the warm pool says it cannot track.

---@diagnostic disable: need-check-nil, inject-field, undefined-field, param-type-mismatch, missing-fields, cast-local-type

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 900) .. ")"
    )
  end

  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/surface_support.lua")
  local entry = S.repo .. "/scripts/testing.lua"

  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  ---The fixture plugin with two specs and a `.testing.lua` of the given extra lines.
  ---@param extra string
  ---@return string root
  local function project(extra)
    local root = S.fixture()
    write(
      root .. "/TESTS/harness.lua",
      [==[
local H = {}
function H.ok(v, msg)
  if not v then
    error("FAIL " .. msg, 2)
  end
end
return H
]==]
    )
    write(
      root .. "/TESTS/a_spec.lua",
      [==[
return function(H)
  require("fxsurf").setup()
  vim.api.nvim_feedkeys(vim.keycode("<Bslash>fo"), "mx", false)
  H.ok(require("fxsurf").calls.open == 1, "the keymap ran")
  vim.cmd("FxOpen")
  H.ok(require("fxsurf").calls.open == 2, "the command ran")
end
]==]
    )
    write(
      root .. "/TESTS/b_spec.lua",
      [==[
return function(H)
  require("fxsurf").setup()
  vim.cmd("Fx status")
  H.ok(require("fxsurf").calls.status == 1, "the route ran")
end
]==]
    )
    -- a busted file: one case per `it`, each with a window of its own
    write(
      root .. "/TESTS/c_spec.lua",
      [==[
describe("windows", function()
  it("opens", function()
    require("fxsurf").setup()
    vim.cmd("FxOpen")
    assert.is_true(require("fxsurf").calls.open >= 1)
  end)
  it("reports", function()
    vim.cmd("Fx status")
    assert.is_true(require("fxsurf").calls.status >= 1)
  end)
end)
]==]
    )
    -- NO `track.hook_runner` here: the runner installs the layer
    write(
      root .. "/TESTS/minimal_init.lua",
      [==[
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
vim.opt.rtp:prepend(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(here))))
]==]
    )
    write(
      root .. "/.testing.lua",
      ([==[
return {
  plugin = "fxsurf",
  dialect = { ["TESTS/c_spec.lua"] = "busted", ["*"] = "h" },
  minit = "TESTS/minimal_init.lua",
  setup = {},
  %s
}
]==]):format(extra)
    )
    return root
  end

  ---@param root string
  ---@param extra? string[]
  ---@return table res, table|nil ir
  local function run(root, extra)
    local ir_path = S.new_dir() .. "/ir.json"
    local argv =
      { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", entry, root }
    vim.list_extend(argv, { "--json", ir_path })
    vim.list_extend(argv, extra or {})
    local res = vim.system(argv, { text = true, env = { TESTING_AGENT = "0" } }):wait(180000)
    local f = io.open(ir_path, "rb")
    local ir
    if f then
      ir = vim.json.decode(f:read("*a"))
      f:close()
    end
    return res, ir
  end

  ---The hit ids of the cases of the busted file, by the name of the `it`.
  ---@param ir table
  ---@return table<string, string[]>
  local function busted_hits(ir)
    local by = {}
    for _, c in ipairs(ir.cases) do
      if c.file == "TESTS/c_spec.lua" then
        by[c.id:match("::(%w+)$") or c.id] = c.surface and c.surface.hit or {}
      end
    end
    return by
  end

  ---@param ir table
  ---@return table<string, string[]|false> by_file the hit ids of the first case of a file (false: no `surface`)
  local function hits_by_file(ir)
    local by = {}
    for _, c in ipairs(ir.cases) do
      by[c.file] = c.surface and c.surface.hit or false
    end
    return by
  end

  S.run(function()
    -- ------------------------------------------------ a child editor per file
    local root = project('surface = { track = true },\n  isolated = "file",')
    local res, ir = run(root)
    ok(res.code == 0, "green: " .. tostring(res.stdout) .. tostring(res.stderr))
    ok(ir ~= nil, "the IR was written")
    local by = hits_by_file(ir)
    eq(
      by["TESTS/a_spec.lua"],
      { "action:fxsurf.open", "binding:<leader>fo", "command:FxOpen" },
      "child per file: a_spec.lua carries the keymap and the command it drove"
    )
    eq(
      by["TESTS/b_spec.lua"],
      { "command:Fx status" },
      "child per file: b_spec.lua carries the route"
    )
    local bc = busted_hits(ir)
    ok(
      vim.tbl_contains(bc.opens or {}, "command:FxOpen")
        and not vim.tbl_contains(bc.opens, "command:Fx status"),
      "child per file, busted: the first `it` carries its own command only: " .. vim.inspect(bc)
    )
    ok(
      vim.tbl_contains(bc.reports or {}, "command:Fx status")
        and not vim.tbl_contains(bc.reports, "command:FxOpen"),
      "child per file, busted: the second `it` carries its own command only: " .. vim.inspect(bc)
    )

    -- `testing surface --from ir.json`: the tracked IR is what the report reads
    local ir_path = S.new_dir() .. "/ir2.json"
    local f = assert(io.open(ir_path, "wb"))
    f:write(vim.json.encode(ir))
    f:close()
    local sres = vim
      .system({
        vim.v.progpath,
        "-n",
        "-i",
        "NONE",
        "--headless",
        "-u",
        "NONE",
        "-l",
        entry,
        "surface",
        root,
        "--from",
        ir_path,
      }, { text = true, env = { TESTING_AGENT = "0" } })
      :wait(180000)
    ok(sres.code == 0, "testing surface works through the command line: " .. tostring(sres.stderr))
    has(sres.stdout, "command:FxOpen", "the report lists the command")
    ok(
      not tostring(sres.stdout):find("the run was not tracked", 1, true),
      "and does not say that the run was untracked"
    )

    -- ------------------------------------------------ this process
    local root2 = project('surface = { track = true },\n  isolated = "none",')
    local res2, ir2 = run(root2)
    ok(
      res2.code == 0,
      "in-process run is green: " .. tostring(res2.stdout) .. tostring(res2.stderr)
    )
    local by2 = hits_by_file(ir2)
    -- in this process the plugin module may be loaded when a case opens, so `api:` hits come on top
    ok(
      vim.tbl_contains(by2["TESTS/a_spec.lua"] or {}, "binding:<leader>fo")
        and vim.tbl_contains(by2["TESTS/a_spec.lua"], "command:FxOpen"),
      "in this process: a_spec.lua carries the keymap and the command it drove: "
        .. vim.inspect(by2["TESTS/a_spec.lua"])
    )
    ok(
      vim.tbl_contains(by2["TESTS/b_spec.lua"] or {}, "command:Fx status")
        and not vim.tbl_contains(by2["TESTS/b_spec.lua"], "command:FxOpen"),
      "in this process: b_spec.lua carries the route and nothing of a_spec.lua: "
        .. vim.inspect(by2["TESTS/b_spec.lua"])
    )

    local bc2 = busted_hits(ir2)
    ok(
      vim.tbl_contains(bc2.opens or {}, "command:FxOpen")
        and not vim.tbl_contains(bc2.opens, "command:Fx status"),
      "in this process, busted: the first `it` carries its own command only: " .. vim.inspect(bc2)
    )
    ok(
      vim.tbl_contains(bc2.reports or {}, "command:Fx status")
        and not vim.tbl_contains(bc2.reports, "command:FxOpen"),
      "in this process, busted: the second `it` carries its own command only: " .. vim.inspect(bc2)
    )

    -- ------------------------------------------------ not asked for: not tracked
    local root3 = project('isolated = "file",')
    local res3, ir3 = run(root3)
    ok(res3.code == 0, "untracked run is green")
    for file, hit in pairs(hits_by_file(ir3)) do
      eq(hit, false, file .. " has no surface when surface.track is off")
    end

    -- ------------------------------------------------ the warm pool cannot track, and says so
    local root4 = project('surface = { track = true },\n  isolated = "file",')
    local res4, ir4 = run(root4, { "--pool-reuse" })
    ok(res4.code == 0, "pool run is green: " .. tostring(res4.stdout) .. tostring(res4.stderr))
    has(
      res4.stderr,
      "surface tracking is not active with the warm pool",
      "the pool says it cannot track"
    )
    for file, hit in pairs(hits_by_file(ir4)) do
      eq(hit, false, file .. " has no surface under the pool")
    end
  end)
end
