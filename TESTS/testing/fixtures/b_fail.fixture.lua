-- Fixture (never a spec of this repo). Dialect B: the helpers of markdown.nvim / diff.nvim.
-- Two checks fail on purpose; the helpers around them are exercised for real.

return function(H)
  local buf = H.scratch("lua")
  H.eq(vim.bo[buf].filetype, "lua", "scratch(ft) sets the filetype")

  local root = H.tmproot("testing_fixture_b")
  H.ok(vim.fn.isdirectory(root) == 1, "tmproot() creates the directory")
  H.ok(not root:find("\\", 1, true), "tmproot() answers forward slashes")

  H.eq(1, 2, "b first wrong") -- MARK:b1

  local dir = H.tmpdir()
  H.ok(dir:sub(-1) == "/" or dir:sub(-1) == "\\", "tmpdir() ends with a separator")
  H.write_file(dir .. "sub/x.txt", { "one", "two" })
  H.eq(#vim.fn.readfile(dir .. "sub/x.txt"), 2, "write_file() writes both lines")
  H.eq(
    H.canonical(dir .. "sub/../sub/x.txt"),
    H.canonical(dir .. "sub/x.txt"),
    "canonical() folds two spellings of one file"
  )

  H.ok(nil, "b second wrong") -- MARK:b2
  H.ok(rawget(H, "no_such_key") == nil, "nothing is defined under an unknown key")
end
