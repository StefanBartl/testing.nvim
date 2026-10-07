---@module 'testing.scaffold'
---@brief `testing init`: generates the test setup of a plugin repository.
---@description
--- `M.init(root, opts)` writes, below `root`:
---
---   .testing.lua                  configuration of testing.nvim (plugin name, dependencies)
---   TESTS/minimal_init.lua        runtimepath for isolated runs; resolves every dependency in the
---                                 four places and exits 1 naming ALL of them when one is missing (NEW-39/40)
---   TESTS/<plugin>/load_spec.lua  a first spec that can fail: the module of the plugin must load
---   scripts/test.sh               the runner; same resolution, exit 1 and a message instead of a silent
---                                 or green run when nvim, testing.nvim or a dependency is missing (NEW-40)
---   .github/workflows/ci.yml      3-OS matrix, timeout-minutes, the JSON IR uploaded when a run fails,
---                                 lib.nvim and testing.nvim checked out from `ci-verified`
---   stylua.toml, .luacheckrc, .gitattributes   (NEW-45, NEW-49) so the generated files are lint-clean
---
--- Rules:
---   * An existing file is NEVER overwritten: it is reported in `skipped`. `opts.force = true`
---     replaces it (atomically); the CLI maps that to the explicit `--force` flag, nothing else
---     turns it on.
---   * The plugin name comes from `opts.plugin`, else from `lua/<name>` (the only directory below
---     `lua/`, or the one that matches the repository name), else from the repository directory name
---     without `.nvim`. It is sanitized (control sequences removed, then a whitelist, SEC-42) before it
---     becomes part of a path or a file's content; a name that sanitizes to nothing is an error.
---   * The templates are plain files under `scaffold/templates/` (data, not code). They are rendered
---     by `testing.scaffold.render`, which embeds every value in the quoting of the language it lands
---     in (SEC-46). Nothing here starts a process or builds a shell string.
---   * Every file is rendered BEFORE the first one is written: a template or value problem creates nothing.
---   * Never raises: every failure ends in `errors`.
---
--- Contract for the CLI subcommand `init` (`testing.cli` dispatches here):
---
---   local result = require("testing.scaffold").init(root, { force = args.given.force })
---   -- result.created / result.replaced / result.skipped: paths relative to root, forward slashes
---   -- (`replaced` only with force: the file existed and was overwritten)
---   -- result.errors: one "<path>: <reason>" string each (an empty list = success)
---   -- exit code: 0 when #errors == 0, otherwise 3 (infrastructure); skipped is not an error.

local render = require("testing.scaffold.render")

local M = {}

---Owner of the GitHub repositories the generated CI checks the dependencies out of.
M.DEFAULT_OWNER = "StefanBartl"

---Branch the generated CI checks the dependencies out of: it only moves once their own CI is green.
M.DEFAULT_REF = "ci-verified"

---Dependencies of the generated project when `opts.deps` is not given.
---@type string[]
M.DEFAULT_DEPS = { "lib.nvim" }

---@class Testing.Scaffold.FileSpec
---@field path string Path below the root; may hold placeholders.
---@field template string File name below `templates/`.
---@field exec? boolean Mode 0755 instead of 0644.

---The files, in the order they are written.
---@type Testing.Scaffold.FileSpec[]
M.FILES = {
  { path = ".testing.lua", template = "dot_testing.lua.tpl" },
  { path = "TESTS/minimal_init.lua", template = "minimal_init.lua.tpl" },
  { path = "TESTS/@@PLUGIN@@/load_spec.lua", template = "smoke_spec.lua.tpl" },
  { path = "scripts/test.sh", template = "test.sh.tpl", exec = true },
  { path = ".github/workflows/ci.yml", template = "ci.yml.tpl" },
  { path = "stylua.toml", template = "stylua.toml.tpl" },
  { path = ".luacheckrc", template = "luacheckrc.tpl" },
  { path = ".gitattributes", template = "gitattributes.tpl" },
}

---Longest accepted plugin name.
local MAX_NAME = 64

---Directory of the templates.
---@return string
function M.template_dir()
  local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  return vim.fs.dirname(vim.fs.normalize(here)) .. "/templates"
end

---Make a name usable as a path component, a Lua module name and a shell word (SEC-42): escape
---sequences go first, then everything outside `[%w_-]` becomes `_`.
---@param name any
---@return string|nil sanitized nil when nothing usable is left.
function M.sanitize_plugin(name)
  if type(name) ~= "string" then
    return nil
  end
  local s = name:sub(1, 400)
  -- CSI sequences (colors) and OSC sequences (titles, links), then whatever control byte is left.
  s = s:gsub("\27%[[0-9;?]*[%a]", ""):gsub("\27%][^\7\27]*[\7\27]?\\?", ""):gsub("%c", "")
  s = s:gsub("[^%w_%-]", "_"):gsub("_+", "_"):gsub("^[_%-]+", ""):gsub("[_%-]+$", "")
  s = s:sub(1, MAX_NAME):gsub("[_%-]+$", "")
  if s == "" then
    return nil
  end
  return s
end

---Module roots directly below `<root>/lua`: directories, and single-file modules (`lua/x.lua`).
---@param root string
---@return { name: string, entry: boolean }[] roots Sorted by name; `entry`: it has an entry module (`init.lua`, or the file itself).
local function lua_roots(root)
  local roots = {}
  local handle = vim.uv.fs_scandir(root .. "/lua")
  if not handle then
    return roots
  end
  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if name:sub(1, 1) ~= "." then
      if kind == "directory" then
        roots[#roots + 1] = {
          name = name,
          entry = vim.uv.fs_stat(root .. "/lua/" .. name .. "/init.lua") ~= nil,
        }
      elseif kind == "file" and name:match("%.lua$") then
        roots[#roots + 1] = { name = name:gsub("%.lua$", ""), entry = true }
      end
    end
  end
  table.sort(roots, function(x, y)
    return x.name < y.name
  end)
  return roots
end

---A module name and a repository name are "the same" when they differ only in case and in `-` / `_`
---(`buffer-ctx.nvim` ships `lua/buffer_ctx`).
---@param s string
---@return string
local function loose(s)
  return (s:lower():gsub("[%-_]", ""))
end

---Plugin name of a repository: the Lua module root below `lua/` (the only one, else the only one with an
---entry module, else the one that matches the repository name), else the directory name without
---`.nvim`. The repository name is a fallback, never a preference: a repository called `buffer-ctx.nvim`
---whose module is `lua/buffer_ctx` is `buffer_ctx` (every conformance check is `n/a` under the wrong
---name). The result is sanitized.
---@param root string
---@return string|nil name
---@return string|nil how "lua-dir" or "directory-name"
function M.detect_plugin(root)
  local base = vim.fs.basename(root):gsub("%.nvim$", "")
  local roots = lua_roots(root)
  if #roots == 1 then
    return M.sanitize_plugin(roots[1].name), "lua-dir"
  end
  local with_entry = vim.tbl_filter(function(r)
    return r.entry
  end, roots)
  -- the one that matches the repository name wins among several (any spelling of the separator)
  for _, r in ipairs(roots) do
    if r.name:lower() == base:lower() then
      return M.sanitize_plugin(r.name), "lua-dir"
    end
  end
  for _, r in ipairs(roots) do
    if loose(r.name) == loose(base) then
      return M.sanitize_plugin(r.name), "lua-dir"
    end
  end
  if #with_entry == 1 then
    return M.sanitize_plugin(with_entry[1].name), "lua-dir"
  end
  return M.sanitize_plugin(base), "directory-name"
end

---@param owner any
---@return boolean
local function is_owner(owner)
  return type(owner) == "string" and #owner <= 39 and owner:match("^%w[%w%-]*$") ~= nil
end

---Dependencies of the project as written to `.testing.lua`, validated; the runner itself
---(`testing.nvim`) is not one of them (it is added where it is needed).
---@param deps any
---@return string[]|nil list
---@return string|nil err
local function normalize_deps(deps)
  if deps == nil then
    return (vim.deepcopy(M.DEFAULT_DEPS))
  end
  if type(deps) ~= "table" then
    return nil, "deps must be a list of directory names"
  end
  local out, seen = {}, {}
  for _, name in ipairs(deps) do
    if not require("testing.deps").is_valid_name(name) then
      return nil, ("invalid dependency name %s"):format(vim.inspect(name))
    end
    if name ~= "testing.nvim" and not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  return out
end

---Read a template file.
---@param dir string
---@param name string
---@return string|nil text
---@return string|nil err
local function read_template(dir, name)
  local text, err = require("lib.nvim.fs.read")(dir .. "/" .. name)
  if not text then
    return nil, ("cannot read template %s: %s"):format(name, tostring(err))
  end
  return text
end

---The `uses: actions/checkout` steps of the CI job, one per dependency.
---@param names string[] Runner first, then the project's dependencies.
---@param owner string
---@param dir string Template directory.
---@param prefix? string
---@param ref? string Branch to check out (default `ci-verified`).
---@return string|nil block
---@return string|nil err
local function dep_steps(names, owner, dir, prefix, ref)
  local tpl, err = read_template(dir, "ci_dep_step.yml.tpl")
  if not tpl then
    return nil, err
  end
  local steps = {}
  for _, name in ipairs(names) do
    local branch = ref or M.DEFAULT_REF
    local note = branch == M.DEFAULT_REF
        and "Checked out from the branch that only moves once the dependency's own CI is green."
      or ("%s has no %s branch: checked out from %s (switch to %s once it exists)."):format(
        name,
        M.DEFAULT_REF,
        branch,
        M.DEFAULT_REF
      )
    local text, rerr = render.render(tpl, {
      NAME = name,
      REPO = owner .. "/" .. name,
      PREFIX = prefix or ".deps/",
      REF = branch,
      NOTE = note,
    })
    if not text then
      return nil, rerr
    end
    steps[#steps + 1] = (text:gsub("\n+$", ""))
  end
  return table.concat(steps, "\n")
end

---Template variables of one project: the values every template of `M.FILES` (and the migration
---templates) is rendered with. The caller has already validated `plugin`, `deps` and `owner`.
---@param plugin string Sanitized plugin name.
---@param deps string[] Dependencies besides testing.nvim.
---@param owner string GitHub owner of the dependency repositories.
---@param extra? table<string, Testing.Scaffold.Value> Additional placeholders (e.g. `RUN_ARGS`).
---@return table<string, Testing.Scaffold.Value>|nil vars
---@return string|nil err
function M.build_vars(plugin, deps, owner, extra)
  local all = { "testing.nvim" }
  vim.list_extend(all, deps)
  local steps, err = dep_steps(all, owner, M.template_dir())
  if not steps then
    return nil, err
  end
  local vars = {
    PLUGIN = plugin,
    DEPS = deps,
    ALL_DEPS = all,
    DEP_STEPS = steps,
    -- Extra arguments of `testing run .` baked into scripts/test.sh (empty: nothing).
    RUN_ARGS = "",
  }
  for k, v in pairs(extra or {}) do
    vars[k] = v
  end
  return vars
end

---Render one template file below `templates/` with `vars`.
---@param template string File name below `templates/`.
---@param vars table<string, Testing.Scaffold.Value>
---@return string|nil text
---@return string|nil err
function M.render_template(template, vars)
  local tpl, err = read_template(M.template_dir(), template)
  if not tpl then
    return nil, err
  end
  return render.render(tpl, vars)
end

---The `uses: actions/checkout` step (with its comment) that puts one dependency on `.deps/<name>`
---from the `ci-verified` branch, at the indentation of a step below `steps:` (6 spaces).
---@param name string Directory name of the dependency; must pass `testing.deps.is_valid_name`.
---@param owner? string GitHub owner (default `M.DEFAULT_OWNER`).
---@param prefix? string Directory prefix of `path:` (default `.deps/`; "" = a sibling of the workspace root).
---@param ref? string Branch to check out: `ci-verified` (default), or `main` for a repository that has no such branch yet.
---@return string|nil text No trailing newline.
---@return string|nil err
function M.dep_step(name, owner, prefix, ref)
  if owner == nil then
    owner = M.DEFAULT_OWNER
  end
  if not require("testing.deps").is_valid_name(name) then
    return nil, ("invalid dependency name %s"):format(vim.inspect(name))
  end
  if not is_owner(owner) then
    return nil, ("invalid owner %s"):format(vim.inspect(owner))
  end
  if
    prefix ~= nil
    and (
      type(prefix) ~= "string"
      or prefix:match("^[%w._/%-]*$") == nil
      or prefix:find("..", 1, true)
      or prefix:sub(1, 1) == "/"
    )
  then
    return nil, "invalid path prefix"
  end
  if ref ~= nil and (type(ref) ~= "string" or ref:match("^[%w][%w._/%-]*$") == nil) then
    return nil, "invalid ref"
  end
  return dep_steps({ name }, owner, M.template_dir(), prefix, ref)
end

---Path relative to the root, for the report.
---@param path string Absolute.
---@param root string Absolute, no trailing slash.
---@return string rel
local function show(path, root)
  return path:sub(#root + 2)
end

---Write one file. Returns what happened: "created", "skipped" or nil plus an error.
---@param path string Absolute.
---@param text string
---@param spec Testing.Scaffold.FileSpec
---@param force boolean
---@return "created"|"replaced"|"skipped"|nil outcome
---@return string|nil err
local function write_file(path, text, spec, force)
  local uv = vim.uv
  local mode = spec.exec and tonumber("755", 8) or tonumber("644", 8)
  local existing = uv.fs_lstat(path)
  if existing and not force then
    return "skipped"
  end
  if existing and existing.type == "directory" then
    return nil, "a directory is in the way"
  end

  local made, merr = require("lib.nvim.fs.mkdirp")(vim.fs.dirname(path))
  if not made then
    return nil, tostring(merr)
  end

  if existing then
    local ok, err = require("lib.nvim.fs.write.atomic")(path, text)
    if not ok then
      return nil, tostring(err)
    end
  else
    -- Exclusive create: a file that appears between the check above and here is not overwritten.
    local fd, oerr, oname = uv.fs_open(path, "wx", mode)
    if not fd then
      if oname == "EEXIST" then
        return "skipped"
      end
      return nil, tostring(oerr)
    end
    local wrote, werr = uv.fs_write(fd, text, 0)
    local closed = uv.fs_close(fd)
    if not wrote or wrote ~= #text or not closed then
      pcall(uv.fs_unlink, path)
      return nil, "write failed: " .. tostring(werr or path)
    end
  end
  if spec.exec then
    -- Best effort: a file system without modes (FAT, some Windows setups) keeps what it has.
    pcall(uv.fs_chmod, path, mode)
  end
  return existing and "replaced" or "created"
end

---Generate the test setup below `root`.
---@param root string Directory of the project; must exist.
---@param opts? Testing.Scaffold.Opts
---@return Testing.Scaffold.Result
function M.init(root, opts)
  opts = opts or {}
  ---@type Testing.Scaffold.Result
  local result = { created = {}, replaced = {}, skipped = {}, errors = {} }
  ---@param msg string
  local function fail(msg)
    result.errors[#result.errors + 1] = msg
  end

  local ok, perr = pcall(function()
    if type(root) ~= "string" or root == "" then
      fail("no root given")
      return
    end
    local abs = vim.fs.normalize(vim.fn.fnamemodify(root, ":p")):gsub("/+$", "")
    if vim.fn.isdirectory(abs) ~= 1 then
      fail(("%s: not a directory"):format(abs))
      return
    end

    local plugin = opts.plugin
    if plugin ~= nil then
      plugin = M.sanitize_plugin(plugin)
      if not plugin then
        fail(
          ("plugin name %s has no usable character (letters, digits, _ and - are kept)"):format(
            vim.inspect(opts.plugin)
          )
        )
        return
      end
    else
      plugin = M.detect_plugin(abs)
      if not plugin then
        fail(("cannot derive a plugin name from %s; pass it explicitly"):format(abs))
        return
      end
    end
    result.plugin = plugin
    ---@cast plugin string

    local deps, derr = normalize_deps(opts.deps)
    if not deps then
      fail(tostring(derr))
      return
    end
    local owner = opts.owner == nil and M.DEFAULT_OWNER or opts.owner
    if not is_owner(owner) then
      fail(("invalid owner %s"):format(vim.inspect(owner)))
      return
    end
    ---@cast owner string

    local dir = M.template_dir()
    local vars, verr = M.build_vars(plugin, deps, owner)
    if not vars then
      fail(tostring(verr))
      return
    end

    -- Render everything first: a problem must not leave half a setup behind.
    ---@type { path: string, rel: string, text: string, spec: Testing.Scaffold.FileSpec }[]
    local planned = {}
    for _, spec in ipairs(M.FILES) do
      local rel, rerr = render.render(spec.path, vars)
      local tpl, terr = read_template(dir, spec.template)
      local text, xerr
      if rel and tpl then
        text, xerr = render.render(tpl, vars)
      end
      if not (rel and tpl and text) then
        fail(("%s: %s"):format(spec.path, tostring(rerr or terr or xerr)))
      else
        planned[#planned + 1] = { path = abs .. "/" .. rel, rel = rel, text = text, spec = spec }
      end
    end
    if #result.errors > 0 then
      return
    end

    for _, item in ipairs(planned) do
      local outcome, werr = write_file(item.path, item.text, item.spec, opts.force == true)
      if outcome == "created" then
        result.created[#result.created + 1] = show(item.path, abs)
      elseif outcome == "replaced" then
        result.replaced[#result.replaced + 1] = show(item.path, abs)
      elseif outcome == "skipped" then
        result.skipped[#result.skipped + 1] = show(item.path, abs)
      else
        fail(("%s: %s"):format(item.rel, tostring(werr)))
      end
    end
  end)
  if not ok then
    fail("internal error: " .. tostring(perr))
  end
  return result
end

return M
