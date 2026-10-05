-- Fixture (never a spec of this repo). Dialect C: the helpers of images.nvim.
-- Two checks fail on purpose; the helpers around them are exercised for real.

return function(H)
  local buf = H.scratch({ "alpha", "beta" }, "lua")
  H.eq(vim.bo[buf].filetype, "lua", "scratch(lines, ft) sets the filetype")
  H.eq(#vim.api.nvim_buf_get_lines(buf, 0, -1, false), 2, "scratch(lines, ft) sets the lines")

  H.falsy(false, "falsy holds")
  H.falsy("truthy", "falsy fails on a truthy value") -- MARK:c1
  H.contains("haystack", "hay", "contains holds")
  H.contains("haystack", "needle", "contains fails") -- MARK:c2
  H.contains(nil, "x", "a non-string haystack fails, it does not raise") -- MARK:c3

  local seen
  local result = H.tmpdir(function(dir)
    seen = dir
    H.write(dir .. "/deep/file.txt", "content")
    H.eq(table.concat(vim.fn.readfile(dir .. "/deep/file.txt"), "\n"), "content", "write() works")
    return "returned"
  end)
  H.eq(result, "returned", "tmpdir(fn) returns what fn returns")
  H.eq(vim.fn.isdirectory(seen), 0, "tmpdir(fn) removes the directory afterwards")
end
