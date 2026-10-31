-- TESTS/testing/export_redact_spec.lua -- no path of this machine in the export form of `testing-export/1`: the
-- messages of last.json (unredacted there, with the repository and a file below $HOME) are redacted as the IR
-- redacts them, the absolute `root` is only in the local form, and the leak detector finds an absolute path that got
-- past the redaction (an injected one, and the whole export refused when the redaction is switched off).

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

return function(H)
  local ok, eq, has = H.ok, H.eq, H.has
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. ")"
    )
  end
  local export = require("testing.export")
  local fixture = dofile(
    vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))) .. "/export_fixture.lua"
  )
  local is_windows = require("testing.platform").is_windows()

  local base = fixture.base("redact")
  local fx = fixture.build(base)
  local HOME = vim.fs.normalize(vim.uv.os_homedir())
  local okp, pw = pcall(vim.uv.os_get_passwd)
  local USER = okp and type(pw) == "table" and pw.username or nil

  local restore = fixture.install()
  local bundle, berr = export.export(fixture.opts(fx))
  local lfleet = export.fleet(fixture.opts(fx, { form = "local" }))
  local lrepo = export.repo(fx.beta, fixture.opts(fx, { form = "local" }))
  local erepo = export.repo(fx.beta, fixture.opts(fx))
  restore()
  ok(bundle, "export: " .. tostring(berr))

  -- the fixture really has the leak the export must close: last.json names the repository and $HOME
  local sdir = require("testing.history").dir(fx.beta, { state_dir = fx.state })
  local raw = fixture.read(sdir .. "/last.json")
  has(raw, fx.home_file, "last.json holds the file below $HOME unredacted (the source of the leak)")

  -- ── the export form: nothing of this machine, in any spelling ──
  local all = {}
  for _, f in ipairs(bundle.files) do
    all[#all + 1] = f.text
  end
  all[#all + 1] = bundle.manifest.text
  local text = table.concat(all, "\n")
  -- the JSON text with its escapes undone for slashes, compared without case (a Windows path)
  local plain = text:gsub("\\\\", "/"):lower()
  lacks(plain, HOME:lower(), "no home directory in the export")
  lacks(plain, base:lower(), "no path of the fixture in the export")
  lacks(plain, "/home/", "no /home/")
  lacks(plain, "/users/", "no /Users/")
  ok(not plain:find("%f[%w]%a:/"), "no drive letter path")
  ok(not text:find('"root"', 1, true), "no root field in the export form")
  if USER and #USER >= 3 then
    ok(not plain:find("%f[%w]" .. vim.pesc(USER:lower()) .. "%f[%W]"), "no user name in the export")
  end
  local beta_text
  for _, f in ipairs(bundle.files) do
    if f.path:match("^repos/beta") then
      beta_text = f.text
    end
  end
  has(
    beta_text,
    "\\u003cHOME>/secret-notes/beta.txt",
    "the file below $HOME is <HOME>/... (the redaction of the IR)"
  )
  has(beta_text, "\\u003cREPO>/lua/beta/parser.lua:40", "the repository is <REPO>")
  has(beta_text, '"line one\\nline two"', "expected keeps its line breaks")
  eq(#export.leaks(vim.json.decode(beta_text)), 0, "the detector finds nothing in the export")

  -- ── the local form: root only there, everything else the same as the export ──
  eq(lrepo.root, fx.beta, "the local repo document names its root")
  eq(lrepo.repo.root, fx.beta, "and its row")
  eq(lfleet.root, fx.root, "the local fleet names the repos root")
  for _, row in ipairs(lfleet.repos) do
    eq(
      row.root,
      fx.root .. "/" .. row.name,
      row.name .. ": the row's root is the absolute directory"
    )
  end
  local stripped = vim.deepcopy(lrepo)
  stripped.root, stripped.repo.root, stripped.form = nil, nil, "export"
  stripped.digest, erepo.digest = nil, nil
  eq(
    stripped,
    erepo,
    "the local form is the export form plus root: free texts are redacted in both"
  )
  ok(#export.leaks(lrepo) > 0, "the detector does see the root of the local form")

  -- ── the redaction of a free text, one by one ──
  do
    local s = export.clean("open " .. HOME .. "/notes/a.txt failed", fx.beta, fx.state)
    eq(s, "open <HOME>/notes/a.txt failed", "a path below $HOME")
    if is_windows then
      -- the same home with backslashes and in upper case is the same folder on Windows
      local back = HOME:gsub("/", "\\"):upper() .. "\\notes\\a.txt"
      local cleaned = export.clean("open " .. back, fx.beta, fx.state)
      eq(
        #export.leaks({ cleaned }),
        0,
        "a backslash spelling of $HOME in another case: " .. cleaned
      )
    end
    eq(
      export.clean("see /opt/tool/bin/x and C:\\tools\\x.exe", fx.beta, fx.state),
      "see <PATH> and <PATH>",
      "any other absolute path is <PATH>"
    )
    eq(
      export.clean(fx.state .. "/testing/x.json is broken", fx.beta, fx.state),
      "<STATE>/testing/x.json is broken",
      "the state directory is <STATE>"
    )
    if USER and #USER >= 3 then
      local s2 = export.clean("run by " .. USER, fx.beta, fx.state)
      eq(#export.leaks({ s2 }), 0, "the user name is redacted: " .. tostring(s2))
    end
    -- the shapes the POSIX rule cannot see: a file URI, a UNC path with forward slashes, a path after a `>`
    for _, shape in ipairs({
      { "cannot load file:///opt/corp/proj/x.lua", "cannot load <PATH>" },
      { "open //fileserver/share/secret.txt", "open <PATH>" },
      { "<nil>/etc/corp/secret", "<nil><PATH>" },
      { "FILE:///C:/corp/x.txt here", "<PATH> here" },
    }) do
      local cleaned = export.clean(shape[1], fx.beta, fx.state)
      eq(cleaned, shape[2], "redacted: " .. shape[1])
      eq(
        #export.leaks({ cleaned }),
        0,
        "and the detector finds nothing left: " .. tostring(cleaned)
      )
    end
    eq(
      export.clean("see https://github.com/o/r and <REPO>/a and <HOME>/b", fx.beta, fx.state),
      "see https://github.com/o/r and <REPO>/a and <HOME>/b",
      "a link and the placeholders stay"
    )
    -- a bare secret of the environment (not a NAME=value pair) is <ENV>
    local secret = "s3cr3t-" .. string.rep("Kx", 10)
    vim.env.EXPORT_SPEC_TOKEN = secret
    local cs = export.clean("auth with " .. secret .. " failed", fx.beta, fx.state)
    vim.env.EXPORT_SPEC_TOKEN = nil
    eq(cs, "auth with <ENV> failed", "a bare token of the environment")
    local long = export.clean(string.rep("x", 10000), fx.beta, fx.state, export.TEXT_MAX)
    eq(#long, export.TEXT_MAX, "a failure text is cut to its budget")
  end

  -- ── the detector: an absolute path injected after the redaction is found (and where, never what) ──
  do
    local function found(value, what)
      local leaks = export.leaks({ repos = { { note = value } } }, { roots = { fx.root } })
      ok(#leaks > 0, what .. " is found")
      if leaks[1] then
        eq(leaks[1].path, "$.repos[0].note", what .. ": where")
        lacks(vim.inspect(leaks), value, what .. ": the finding does not repeat the text")
      end
    end
    found("cannot open C:\\Users\\someone\\secret.txt", "a drive path")
    found("cannot open D:/data/x", "a drive path with slashes")
    found("cannot open /home/someone/secret.txt", "a POSIX path")
    found("(/var/lib/x)", "a POSIX path in brackets")
    found("\\\\fileserver\\share\\x", "a UNC path")
    found("open //fileserver/share/secret.txt", "a UNC path with forward slashes")
    found("//fileserver/share", "a UNC path with forward slashes at the start")
    found("cannot load file:///srv/data/secret.txt", "a file URI")
    found("<nil>/etc/corp/secret", "a path after a closing >")
    found("below " .. HOME .. "x", "the home directory")
    found("in " .. fx.root:gsub("/", "\\") .. "\\alpha", "a root, with backslashes")
    if USER and #USER >= 3 then
      found("hello " .. USER .. " here", "the user name")
    end
    local leaks = export.leaks({ [HOME] = 1 })
    ok(#leaks > 0, "a key is checked too")
    -- a root is a whole path: where a path begins, up to the end of a segment
    eq(
      #export.leaks({ "<REPO>/TESTS/rootless_spec.lua" }, { home = "/root", user = "" }),
      0,
      "home /root is not in rootless_spec.lua"
    )
    eq(export.find_root("<repo>/tests/rootless_spec.lua", "/root"), false, "not inside a word")
    eq(export.find_root("<repo>/tests/root/x", "/root"), false, "not inside a relative path")
    eq(export.find_root("in /root/x", "/root"), true, "a path below it")
    eq(export.find_root("/root", "/root"), true, "the root itself")
    eq(export.find_root("c:/users/bob/x", "c:/users/bob"), true, "a drive root")
    eq(export.find_root("c:/users/bobby", "c:/users/bob"), false, "not a longer name")
    -- the user name in a name the user chose (a repository, its key, its file) is no leak; in a free text it is
    local named = {
      repos = { { name = "runner.nvim", key = "runner.nvim-0123456789ab" } },
      files = { { path = "repos/runner.nvim-0123456789ab.json" } },
    }
    eq(
      #export.leaks(named, { user = "runner", home = "/nohome" }),
      0,
      "a repository named after the user"
    )
    eq(
      #export.leaks({ repo = { name = "runner.nvim" } }, { user = "runner", home = "/nohome" }),
      0,
      "the repo document's row"
    )
    eq(
      #export.leaks({ repos = { { note = "runner here" } } }, { user = "runner", home = "/nohome" }),
      1,
      "the user name in a free text is found"
    )
    -- a secret of the environment that got past the redaction
    local sl = export.leaks({ "x tok-abcdefgh123 y" }, { secrets = { "tok-abcdefgh123" } })
    eq(#sl, 1, "a secret is found")
    eq(sl[1] and sl[1].what, "a secret of the environment", "named")
    for _, clean in ipairs({
      "<REPO>/lua/x.lua:12: boom",
      "<HOME>/a and <PATH>",
      "https://github.com/owner/repo/actions/runs/1",
      "TESTS/x_spec.lua::group::a/b case",
      "expected 1/2, got 3/4",
      "2026-10-31T12:00:00Z",
    }) do
      eq(#export.leaks({ clean }), 0, "no finding in " .. clean)
    end
  end

  -- ── with the redaction switched off the export is refused, never written with the leak ──
  do
    local saved = export.clean
    export.clean = function(s)
      return type(s) == "string" and s or nil
    end
    local r2 = fixture.install()
    local doc, err = export.repo(fx.beta, fixture.opts(fx))
    local b2, err2 = export.export(fixture.opts(fx))
    r2()
    export.clean = saved
    eq(doc, nil, "the repo document is refused")
    has(tostring(err), "would leak a path of this machine", "and says why")
    has(tostring(err), "$.cases[0].message", "and where")
    lacks(tostring(err), fx.home_file, "but not what")
    eq(b2, nil, "the export is refused")
    has(tostring(err2), "would leak", "the export says why")
  end

  -- ── the fleet document is checked on its own: a leak only in a fleet row refuses fleet() and export() ──
  do
    local saved = export.clean
    export.clean = function(s)
      return type(s) == "string" and s or nil
    end
    local r3 = fixture.install()
    local saved_head = export.deps.head
    export.deps.head = function(dir)
      return { sha = string.rep("3", 40), branch = dir .. "/branch", dirty = false }
    end
    local fdoc, ferr = export.fleet(fixture.opts(fx))
    local b3, err3 = export.export(fixture.opts(fx))
    export.deps.head = saved_head
    r3()
    export.clean = saved
    eq(fdoc, nil, "fleet() is refused")
    has(tostring(ferr), "the fleet document would leak", "fleet() says why")
    has(tostring(ferr), "$.repos[0].head.branch", "and where")
    eq(b3, nil, "export() is refused")
    has(tostring(err3), "the fleet document would leak", "by the check of the fleet document")
  end

  vim.fn.delete(base, "rf")
end
