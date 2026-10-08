-- TESTS/testing/migrate_ci_libpath_spec.lua -- the migration removes the LIB_NVIM_PATH of a run step only where
-- `scripts/test.sh` finds lib.nvim by itself (`<root>/.deps/lib.nvim`, `<root>/../lib.nvim`): with the repository in the
-- workspace root, `${{ github.workspace }}/lib.nvim` is a folder INSIDE the repository, which the script does not look
-- in. There the line is renamed to the spelling the script reads (`LIB_NVIM_DIR`), and new checkouts go to `.deps/`.

---@diagnostic disable: need-check-nil, missing-fields

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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 700) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 700) .. ")"
    )
  end
  local ci = require("testing.migrate.ci")

  local ctx = {
    drop_plenary = false,
    fleet_deps = { "lib.nvim" },
    is_self = true,
    dep_step = function()
      return nil
    end,
    artifact_step = function()
      return nil
    end,
  }

  ---A workflow whose job checks the repository out (with `own_path`, or into the workspace root), checks lib.nvim
  ---out at `lib_path`, and runs `scripts/test.sh` with `lib_env` in its env block.
  ---@param own_path string|nil
  ---@param lib_path string
  ---@param lib_env string
  ---@return string
  local function workflow(own_path, lib_path, lib_env)
    local lines = {
      "name: ci",
      "on: [push]",
      "jobs:",
      "  tests:",
      "    runs-on: ubuntu-latest",
      "    steps:",
      "      - uses: actions/checkout@v5",
    }
    if own_path then
      vim.list_extend(lines, { "        with:", "          path: " .. own_path })
    end
    vim.list_extend(lines, {
      "      - uses: actions/checkout@v5",
      "        with:",
      "          repository: StefanBartl/lib.nvim",
      "          path: " .. lib_path,
      "          ref: ci-verified",
      "      - name: Run the specs",
      "        env:",
      "          LIB_NVIM_PATH: " .. lib_env,
      "          OTHER: 1",
      "        run: bash scripts/test.sh",
      "",
    })
    return table.concat(lines, "\n")
  end

  ---@param src string
  ---@return Testing.Migrate.CiEdit
  local function edit(src)
    local r = ci.edit(src, ctx)
    ok(r.text ~= nil, "the workflow is edited")
    return r
  end

  local WS = "${{ github.workspace }}"

  -- the repository in a folder of the workspace, lib.nvim next to it: test.sh finds it (`../lib.nvim`), the line goes
  local r = edit(workflow("repo.nvim", "lib.nvim", WS .. "/lib.nvim"))
  lacks(r.text, "LIB_NVIM_PATH", "sibling layout: the line goes")
  lacks(r.text, "LIB_NVIM_DIR", "and is not renamed")
  ok(
    vim.tbl_contains(
      r.changes,
      "job tests: LIB_NVIM_PATH is removed from the run step (scripts/test.sh finds lib.nvim itself)"
    ),
    "and the change says so: " .. vim.inspect(r.changes)
  )

  -- the repository in the workspace root, lib.nvim in a folder of it: the script does not look there, the name it reads
  -- is the way to say where (the line is renamed, not dropped)
  r = edit(workflow(nil, "lib.nvim", WS .. "/lib.nvim"))
  lacks(r.text, "LIB_NVIM_PATH", "root layout: the old name is gone")
  has(
    r.text,
    "LIB_NVIM_DIR: " .. WS .. "/lib.nvim",
    "and the value stays, under the name test.sh reads"
  )
  ok(
    not vim.tbl_contains(
      r.changes,
      "job tests: LIB_NVIM_PATH is removed from the run step (scripts/test.sh finds lib.nvim itself)"
    ),
    "nothing claims that test.sh finds it by itself"
  )

  -- a checkout of lib.nvim under `.deps/` IS where the script looks, with the repository in the root
  r = edit(workflow(nil, ".deps/lib.nvim", WS .. "/.deps/lib.nvim"))
  lacks(r.text, "LIB_NVIM_PATH", "root layout, .deps/lib.nvim: the line goes")
  lacks(r.text, "LIB_NVIM_DIR", "and is not renamed")

  -- two folders deep, `../lib.nvim` is not the workspace folder either
  r = edit(workflow("a/repo.nvim", "lib.nvim", WS .. "/lib.nvim"))
  lacks(r.text, "LIB_NVIM_PATH", "a repository two folders deep: the old name is gone")
  has(r.text, "LIB_NVIM_DIR: " .. WS .. "/lib.nvim", "renamed")

  -- quotes and blanks around the value do not matter
  r = edit(workflow("repo.nvim", "lib.nvim", '"' .. WS .. '/lib.nvim"   '))
  lacks(r.text, "LIB_NVIM_PATH", "a quoted value with blanks behind it: the line goes")

  -- ---------------------------------------------------------------- where new checkouts go
  local function prefix_of(src)
    local doc = assert(ci.parse(src))
    return ci.checkout_prefix(doc, doc.jobs[1])
  end
  eq(prefix_of(workflow("repo.nvim", "lib.nvim", "x")), "", "a checkout next to the existing one")
  eq(prefix_of(workflow(nil, ".deps/lib.nvim", "x")), ".deps/", "an existing .deps/ layout stays")

  -- With the repository in the workspace root, a new `path: testing.nvim` is a folder OF the repository (not next to
  -- it, as in the other layout): the script does not look there, so the edit says how to name the place.
  local scaffold = require("testing.scaffold")
  local adding = vim.tbl_extend("force", ctx, {
    is_self = false,
    dep_step = function(name, prefix)
      return scaffold.dep_step(name, "StefanBartl", prefix)
    end,
  })
  local root_layout = ci.edit(workflow(nil, "lib.nvim", WS .. "/lib.nvim"), adding)
  has(
    root_layout.text,
    "path: testing.nvim\n",
    "the checkout follows the layout of the existing one"
  )
  local note = table.concat(root_layout.notes, "\n")
  has(note, "checked out into the workspace root", "the root layout is named")
  has(note, "TESTING_NVIM_DIR", "with the variable that names the place")
  local sibling_layout = ci.edit(workflow("repo.nvim", "lib.nvim", WS .. "/lib.nvim"), adding)
  has(sibling_layout.text, "path: testing.nvim\n", "the same checkout in the other layout")
  lacks(
    table.concat(sibling_layout.notes, "\n"),
    "workspace root",
    "next to the repository the script finds it: no note"
  )

  local doc = assert(ci.parse(workflow("./repo.nvim/", "lib.nvim", "x")))
  eq(ci.own_checkout_path(doc, doc.jobs[1]), "repo.nvim", "the own path is normalized")
  doc = assert(ci.parse(workflow(nil, "lib.nvim", "x")))
  eq(ci.own_checkout_path(doc, doc.jobs[1]), nil, "no path: the workspace root")
end
