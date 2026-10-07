-- TESTS/testing/cache_line_endings_spec.lua -- the cache key does not count line endings: the same commit checked out
-- with CRLF (git's core.autocrlf on a Windows runner) and with LF has the same key. Binary files are hashed as they
-- are, and a spec that looks at line endings itself (a carriage return escape in its code, the option fileformat,
-- a data file with CRLF that it reads) keeps the raw hashes, so a CRLF checkout has another key there.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/cache/support.lua")
  local cache = require("testing.cache")
  local hash = require("testing.cache.hash")

  -- ------------------------------------------------------------------ the normalization itself
  local n, crlf = hash.normalize("a\r\nb\r\n")
  eq({ n, crlf }, { "a\nb\n", true }, "CRLF is read as LF")
  eq({ hash.normalize("a\nb\n") }, { "a\nb\n", false }, "LF stays and is not marked")
  eq({ hash.normalize("a\rb") }, { "a\rb", false }, "a lone CR stays (old Mac files are not LF)")
  eq({ hash.normalize("a\n\r\nb") }, { "a\n\nb", true }, "a mixed file is read line by line")
  eq(
    { hash.normalize("a\0b\r\n") },
    { "a\0b\r\n", false },
    "a NUL byte in the head: binary, as it is"
  )
  local late_nul = ("x"):rep(hash.BINARY_PROBE) .. "\0\r\n"
  eq(
    { hash.normalize(late_nul) },
    { (late_nul:gsub("\r\n", "\n")), true },
    "a NUL after the probe is text"
  )

  -- files in a directory: the hasher gives the normalized hash, and the raw one on request
  local tmp = vim.fs.normalize(vim.fn.tempname())
  S.write(tmp .. "/lf.txt", "one\ntwo\n")
  S.write(tmp .. "/crlf.txt", "one\r\ntwo\r\n")
  S.write(tmp .. "/bin.dat", "\0\1\2\r\n\3")
  local h = hash.new()
  local lf, _, lf_flag = h:file(tmp .. "/lf.txt")
  local cr, _, cr_flag = h:file(tmp .. "/crlf.txt")
  eq(cr, lf, "LF and CRLF text have the same hash")
  eq({ lf_flag, cr_flag }, { false, true }, "and only the CRLF one is flagged")
  eq(
    h:file(tmp .. "/crlf.txt", true),
    vim.fn.sha256("one\r\ntwo\r\n"),
    "the raw hash is the hash of the bytes"
  )
  eq(h:file(tmp .. "/lf.txt", true), lf, "raw and normalized are one hash for an LF file")
  local bin, _, bin_flag = h:file(tmp .. "/bin.dat")
  eq(
    { bin, bin_flag },
    { vim.fn.sha256("\0\1\2\r\n\3"), false },
    "a binary file is hashed as it is"
  )
  S.write(tmp .. "/other.txt", "one\r\ntwo!\r\n")
  ok(h:file(tmp .. "/other.txt") ~= cr, "a changed text has another hash")

  -- the index keeps both hashes and the flag, and an index of the old layout is not used
  local index = tmp .. "/index.json"
  local h2 = hash.new(index)
  local first = h2:file(tmp .. "/crlf.txt")
  ok(h2:flush(), "the index is written")
  local h3 = hash.new(index)
  local again, _, flag = h3:file(tmp .. "/crlf.txt")
  eq({ again, flag, h3.reused }, { first, true, 1 }, "read back: same hash, flagged, no file read")
  eq(h3:file(tmp .. "/crlf.txt", true), vim.fn.sha256("one\r\ntwo\r\n"), "and the raw hash too")
  local decoded = vim.json.decode(S.read(index))
  eq(decoded.v, 3, "the index has the layout version of the normalized hashes")
  decoded.v = 2
  S.write(index, vim.json.encode(decoded))
  local h4 = hash.new(index)
  h4:file(tmp .. "/crlf.txt")
  eq(h4.hashed, 1, "an index of the old layout (raw hashes) is ignored")
  S.remove(tmp)

  -- ------------------------------------------------------------------ what the scanner counts as looking at them
  local scan = require("testing.affected.scan")
  local function looks(code)
    return scan.analyze(code).markers.eol
  end
  ok(looks('local s = "a\\r\\nb"'), "a carriage return escape")
  ok(looks('local s = "\\13"'), "the decimal escape")
  ok(looks('local s = "\\x0D"'), "the hex escape")
  ok(looks("vim.bo.fileformat = 'dos'"), "the option fileformat")
  ok(looks("local crlf = true"), "the word crlf")
  ok(looks("local eol = true"), "the word eol")
  ok(not looks('local s = "C:\\\\repos"'), "an escaped backslash followed by r is a path")
  ok(not looks('local s = "\\130"'), "the escape of byte 130 is not a carriage return")
  ok(not looks("-- crlf in a comment\nreturn 1"), "a comment does not count")
  ok(not looks("local x = require('a.b')"), "plain code does not")
  ok(not looks("local eolian = 1"), "a longer word does not")

  -- ------------------------------------------------------------------ the key
  local files = dofile(dir .. "/fixtures/cache/project.lua")
  local extra = {
    -- a spec that looks at line endings itself: a carriage return escape in its code
    ["TESTS/proj/eol_spec.lua"] = 'return function(H) H.eq(("a\\r\\nb"):find("\\r"), 2, "eol") end\n',
    -- a module of the closure that does
    ["lua/proj/eolmod.lua"] = "return { ff = vim.o.fileformat }\n",
    ["TESTS/proj/eolmod_spec.lua"] = 'local m = require("proj.eolmod")\nreturn function(H) H.ok(m, "m") end\n',
    -- escaped backslash: "C:\\repos" is no carriage return
    ["TESTS/proj/path_spec.lua"] = 'return function(H) H.eq(("C:\\\\repos"):len(), 8, "path") end\n',
  }
  local all = vim.tbl_extend("force", files, extra)
  local function crlf_of(map)
    local out = {}
    for rel, text in pairs(map) do
      out[rel] = (text:gsub("\n", "\r\n"))
    end
    return out
  end
  local lf_root = S.project(extra)
  local crlf_root = S.project(crlf_of(all))

  local function key_in(root, file)
    local k, why, parts = cache.key({ file = file }, {
      root = root,
      cache_dir = vim.fs.normalize(vim.fn.tempname()),
      dep_roots = {},
      runner_version = "runner-1",
      nvim = "0.12.0-test",
      config_digest = "cfg-1",
      dialect = "a",
      env_names = {},
      environ = function()
        return {}
      end,
      hasher = hash.new(),
    })
    return k, why, parts and table.concat(parts, "\n") or ""
  end
  local function has_raw(parts)
    return parts:find("eol raw", 1, true) ~= nil
  end

  -- code and a spec that does not look at line endings: one key for both checkouts
  for _, file in ipairs({
    "TESTS/proj/a_spec.lua",
    "TESTS/proj/pure_spec.lua",
    "TESTS/proj/path_spec.lua",
  }) do
    local k_lf, why, p_lf = key_in(lf_root, file)
    local k_crlf, _, p_crlf = key_in(crlf_root, file)
    ok(k_lf ~= nil, file .. " has a key: " .. tostring(why))
    eq(k_crlf, k_lf, file .. ": LF and CRLF checkouts have the same key")
    ok(not has_raw(p_lf) and not has_raw(p_crlf), file .. ": the hashes are the normalized ones")
  end

  -- a real change is still a change, in either line ending
  local a_key = key_in(crlf_root, "TESTS/proj/a_spec.lua")
  S.edit(crlf_root, "lua/proj/b.lua", "return { v = 2 }\r\n")
  local a_changed = key_in(crlf_root, "TESTS/proj/a_spec.lua")
  ok(a_changed ~= a_key, "an edit of a required module changes the key of a CRLF checkout")
  S.edit(lf_root, "lua/proj/b.lua", "return { v = 2 }\n")
  eq(
    key_in(lf_root, "TESTS/proj/a_spec.lua"),
    a_changed,
    "and the same edit in an LF checkout gives the same key"
  )
  -- a lone CR is a different file
  S.edit(lf_root, "lua/proj/b.lua", "return { v = 2 }\r")
  ok(
    key_in(lf_root, "TESTS/proj/a_spec.lua") ~= a_changed,
    "a lone CR is not a line ending that is ignored"
  )
  S.edit(lf_root, "lua/proj/b.lua", "return { v = 1 }\n")
  S.edit(crlf_root, "lua/proj/b.lua", "return { v = 1 }\r\n")

  -- a spec that looks at line endings itself stays conservative: the raw hashes, so LF and CRLF differ
  for _, file in ipairs({ "TESTS/proj/eol_spec.lua", "TESTS/proj/eolmod_spec.lua" }) do
    local k_lf, why, p_lf = key_in(lf_root, file)
    local k_crlf, _, p_crlf = key_in(crlf_root, file)
    ok(k_lf ~= nil and k_crlf ~= nil, file .. " has a key: " .. tostring(why))
    ok(k_lf ~= k_crlf, file .. ": an LF and a CRLF checkout have different keys")
    ok(
      has_raw(p_lf) and has_raw(p_crlf),
      file .. ": the key says that it is made from the raw hashes"
    )
    eq(key_in(crlf_root, file), k_crlf, file .. ": and it is stable")
  end

  -- a spec that reads data with CRLF: raw hashes too; the same spec on LF data keeps the normalized ones
  local data_spec = "TESTS/proj/inputs_spec.lua" -- `-- @cache-inputs docs/data.txt`
  local k_lf, _, p_lf = key_in(lf_root, data_spec)
  local k_crlf, _, p_crlf = key_in(crlf_root, data_spec)
  ok(k_lf ~= k_crlf, "a spec that reads a file: LF and CRLF data give different keys")
  ok(has_raw(p_crlf) and not has_raw(p_lf), "only the CRLF one is made from the raw hashes")
  -- CRLF data in an otherwise LF project changes only the spec that reads it
  local plain = S.project()
  local mixed = S.project({ ["docs/data.txt"] = "data v1\r\n" })
  ok(
    key_in(mixed, data_spec) ~= key_in(plain, data_spec),
    "CRLF data changes the key of the spec that reads it"
  )
  eq(
    key_in(mixed, "TESTS/proj/a_spec.lua"),
    key_in(plain, "TESTS/proj/a_spec.lua"),
    "and not the key of a spec that does not read it"
  )
  -- a spec that reads the spec root as data (io): the CRLF files there make it conservative
  local reads = "TESTS/proj/reads_spec.lua"
  ok(
    key_in(lf_root, reads) ~= key_in(crlf_root, reads),
    "a spec that reads files: LF and CRLF fixtures give different keys"
  )

  -- the line endings of the runner itself are not part of a spec's key either way: a runner digest is the
  -- tree digest, which reads CRLF as LF
  local runner_lf = S.project()
  local runner_crlf =
    S.project({ ["lua/proj/a.lua"] = 'local b = require("proj.b")\r\nreturn { v = b.v }\r\n' })
  local ht = hash.new()
  eq(
    ht:tree(runner_crlf .. "/lua"),
    ht:tree(runner_lf .. "/lua"),
    "a tree digest does not count line endings"
  )
  ok(select(3, ht:tree(runner_crlf .. "/lua")) == true, "and says that it saw CRLF")

  S.remove(lf_root)
  S.remove(crlf_root)
  S.remove(mixed)
  S.remove(plain)
  S.remove(runner_lf)
  S.remove(runner_crlf)
end
