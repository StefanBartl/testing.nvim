---@module 'testing.bindings.usrcmds'
---@brief Registers the `:Testing` user command (lib.nvim composer verb).
---@description
--- Subcommands (see docs/BINDINGS.md):
---
---   :Testing [run] [<root>] [--file=..] [--filter=..] [--reporter=..] [--rtp=..] [--config=..]
---   :Testing file [<spec>]       run the spec of the current buffer (mapping a source file to its spec is M3)
---   :Testing last                repeat the last run
---   :Testing list [<root>] ...   list what would run
---   :Testing init [<root>] [--force] [--plugin=<name>] [--hooks]   generate the test setup of a plugin repo (--hooks: the git and agent hook recipes instead, never over an existing file)
---   :Testing migrate [dry-run|apply] [<root>] [--fleet-root=<dir>]   plan (or write) the move of a repo to testing.nvim
---   :Testing conformance [<root>] [--gate] [--only=K1,K3] [--skip=K10] [--bridge] [--markdown]   the K1..K15 checks
---   :Testing surface [<root>] [--from=<ir.json>] [--threshold=<n>] [--markdown]   keymaps/commands/... and how much the specs exercised
---   :Testing budget [<root>] [--update] [--allow-new] [--factor=<x>]   measure the performance budgets
---   :Testing cache stats | clear [<root>]   the result cache of the project
---   :Testing health | config | doctor [<root>]
---
--- Runs go to a headless child nvim (`testing.bindings.child`), never into this editor. Completion
--- comes from the same route tree as the dispatch and is computed live (UI-22/23/26): the
--- subcommands and `--flags` from the tree, the reporters from `testing.args.REPORTERS` at the moment
--- of the keypress, the `--file=` candidates from the spec files that exist below the project root now.
--- No keymap is bound here; keymaps are the user's opt-in (`keymaps.lua`).

local M = {}

local registered = false

---Run options of the last `run`/`file`, for `:Testing last`.
---@type { sub: string, opts: Testing.Child.Opts }|nil
M.last_run = nil

---Names of the argument types this module registers with the composer.
M.TYPE_REPORTER = "TESTING_REPORTER"
M.TYPE_SPEC = "TESTING_SPEC"
M.TYPE_MIGRATE = "TESTING_MIGRATE"

---Where the text of `:Testing migrate` goes (a viewer); a spec replaces it.
---@type fun(lines: string[], title: string)
M.viewer = function(lines, title)
  local prefix = require("testing.config").get().notify_prefix
  require("lib.nvim.output").create(prefix).dump(lines, title)
end

---@param path string
---@return string
local function abs(path)
  return (vim.fs.normalize(vim.fn.fnamemodify(path, ":p")):gsub("/+$", ""))
end

---The project root of a command: the explicit directory, else the nearest ancestor of `from` (the
---current directory by default) that holds `.testing.lua`, `TESTS` or `.git`, else the current directory.
---@param explicit? string
---@param from? string A file or directory to start the upward search at.
---@return string root Absolute, forward slashes, no trailing slash.
function M.resolve_root(explicit, from)
  if type(explicit) == "string" and explicit ~= "" then
    return abs(explicit)
  end
  local start = vim.fn.getcwd()
  if from and from ~= "" then
    start = vim.fn.isdirectory(from) == 1 and from or vim.fs.dirname(from)
  end
  local found = require("lib.nvim.fs.find_upward_dir")({ ".testing.lua", "TESTS", ".git" }, start)
  return abs(found or vim.fn.getcwd())
end

---Spec files below `<root>/TESTS`, relative to the root (what `--file=` matches against).
---@param root string
---@return string[]
function M.spec_files(root)
  local found = vim.fs.find(function(name)
    return name:match("_spec%.lua$") ~= nil
  end, { path = root .. "/TESTS", type = "file", limit = 1000 })
  local out = {}
  for _, path in ipairs(found) do
    out[#out + 1] = require("lib.nvim.fs.relpath")(path, root)
  end
  table.sort(out)
  return out
end

---`--rtp`, shared by every command that starts specs. The `desc` of each flag is the line of lib.nvim's
---option float; `TESTS/testing/usrcmds_help_spec.lua` fails for a flag that has none.
---@return table
local function rtp_flag()
  return {
    name = "rtp",
    type = "DIR",
    repeatable = true,
    desc = "Add a directory to the runtimepath of the specs",
  }
end

---The flags of the commands that run or list specs.
---@return table[]
local function run_flags()
  return {
    {
      name = "file",
      type = M.TYPE_SPEC,
      repeatable = true,
      desc = "Only spec files whose relative path contains the text",
    },
    {
      name = "filter",
      type = "STRING",
      repeatable = true,
      desc = "Only cases whose id contains the text (file::describe::it)",
    },
    {
      name = "reporter",
      type = M.TYPE_REPORTER,
      desc = "Reporter that formats what the test process prints",
    },
    rtp_flag(),
    {
      name = "config",
      type = "FILE",
      desc = "Load this config file (inside the root) instead of .testing.lua",
    },
    {
      name = "cached",
      bool = true,
      desc = "Skip spec files unchanged since an earlier green run",
    },
    {
      name = "no-cache",
      bool = true,
      desc = "Never read or write the result cache (wins over --cached)",
    },
    {
      name = "changed",
      bool = true,
      desc = "Only specs reachable from uncommitted changes (vs HEAD)",
    },
    {
      name = "since",
      type = "STRING",
      desc = "Only specs reachable from changes since a git revision",
    },
    {
      name = "shard",
      type = "STRING",
      desc = "Run only shard i/n of the spec files (e.g. 2/4)",
    },
  }
end

---The verbatim arguments of a subcommand with its own grammar.
---@param flags table<string, any>
---@param spec { bool: string[], value: string[] } Flag names that are switches and flags that take a value.
---@return string[] raw
local function raw_args(flags, spec)
  local raw = {}
  for _, name in ipairs(spec.bool) do
    if flags[name] then
      raw[#raw + 1] = "--" .. name
    end
  end
  for _, name in ipairs(spec.value) do
    if type(flags[name]) == "string" then
      raw[#raw + 1] = ("--%s=%s"):format(name, flags[name])
    end
  end
  return raw
end

---`ctx.flags` as the child's flag table.
---@param flags table<string, any>
---@return Testing.Child.Flags
function M.child_flags(flags)
  return {
    file = flags.file,
    filter = flags.filter,
    reporter = flags.reporter,
    rtp = flags.rtp,
    config = flags.config,
    cached = flags.cached or nil,
    no_cache = flags["no-cache"] or nil,
    changed = flags.changed or nil,
    since = flags.since,
    shard = flags.shard,
  }
end

---@param sub "run"|"list"|"doctor"|"conformance"|"surface"|"budget"
---@param opts Testing.Child.Opts
local function start(sub, opts)
  local notify = require("testing.notify").get()
  local ok, err = require("testing.bindings.child").start(sub, opts)
  if not ok then
    notify.error(("cannot start the test process: %s"):format(tostring(err)))
    return
  end
  if sub == "run" then
    M.last_run = { sub = sub, opts = opts }
  end
  notify.info(("testing %s: %s"):format(sub, opts.root))
end

---The relative spec path of the current buffer, or nil with the reason.
---@param path? string Explicit file (else the current buffer's name).
---@return string|nil root
---@return string|nil rel
---@return string|nil err
function M.current_spec(path)
  local file = path
  if not file or file == "" then
    file = vim.api.nvim_buf_get_name(0)
  end
  if file == "" then
    return nil, nil, "the current buffer has no file"
  end
  file = abs(file)
  if not file:match("_spec%.lua$") then
    return nil,
      nil,
      ("%s is not a spec file (*_spec.lua); running the spec of a source file is not implemented yet"):format(
        file
      )
  end
  local root = M.resolve_root(nil, file)
  local rel = require("lib.nvim.fs.relpath")(file, root)
  if rel:sub(1, 3) == "../" or rel:match("^%a:") or rel:sub(1, 1) == "/" then
    return nil, nil, ("%s is outside the project root %s"):format(file, root)
  end
  return root, rel
end

---Handler of `:Testing run` and of the bare `:Testing`.
---@param ctx { args: table<string, any>, flags: table<string, any> }
function M.run_all(ctx)
  start("run", { root = M.resolve_root(ctx.args.root), flags = M.child_flags(ctx.flags) })
end

---`:Testing migrate [dry-run|apply] [<root>]`: plan the migration of a repository (nothing is written
---without the word `apply`, and `apply` refuses a repository with uncommitted changes). The first
---word is the mode when it is `dry-run` or `apply`, else it is the root.
---@param ctx Testing.Usrcmds.MigrateCtx
---@return Testing.Migrate.Plan|nil plan
---@return Testing.Migrate.ApplyResult|nil applied
function M.migrate(ctx)
  local notify = require("testing.notify").get()
  local migrate = require("testing.migrate")
  local mode, root = ctx.args.mode, ctx.args.root
  if mode ~= nil and mode ~= "dry-run" and mode ~= "apply" then
    if root ~= nil then
      notify.error(
        ("testing migrate: %s is neither dry-run nor apply"):format(
          require("testing.migrate.text").show(mode, 60)
        )
      )
      return nil, nil
    end
    mode, root = nil, mode
  end
  local dir = M.resolve_root(root)
  local plan = migrate.run(dir, {
    fleet_root = ctx.flags["fleet-root"],
    branch_exists = require("testing.migrate.branches").exists,
  })
  local applied
  local lines = vim.split(migrate.render(plan, { format = "text" }), "\n", { plain = true })
  local level = "info"
  local summary
  if plan.error then
    level, summary = "error", ("cannot analyse %s: %s"):format(dir, plan.error)
  elseif plan.skipped then
    summary = ("%s is not a migration target"):format(plan.name)
  elseif plan.empty then
    summary = ("%s is migrated: nothing to do"):format(plan.name)
  elseif mode == "apply" then
    applied = migrate.apply(plan, { apply = true })
    if #applied.errors > 0 then
      level, summary = "error", "migration refused: " .. table.concat(applied.errors, "; ")
    else
      summary = ("%s: %d file(s) written: %s"):format(
        plan.name,
        #applied.applied,
        table.concat(applied.applied, ", ")
      )
    end
    vim.list_extend(lines, { "", summary })
  else
    summary = ("%s: %d operation(s) planned (dry run, nothing written; `:Testing migrate apply` writes)"):format(
      plan.name,
      #plan.ops
    )
  end
  M.viewer(lines, "testing migrate " .. plan.name)
  notify[level](summary)
  return plan, applied
end

---The route tree of `:Testing`.
---@return table[]
function M.routes()
  local function notify()
    return require("testing.notify").get()
  end

  return {
    {
      path = { "run" },
      desc = "Run the spec files of the project (headless child nvim)",
      args = { { name = "root", type = "DIR", optional = true } },
      flags = run_flags(),
      run = M.run_all,
    },
    {
      path = { "file" },
      desc = "Run the spec file of the current buffer",
      args = { { name = "spec", type = "FILE", optional = true } },
      flags = { rtp_flag() },
      run = function(ctx)
        local root, rel, err = M.current_spec(ctx.args.spec)
        if not root then
          notify().warn(tostring(err))
          return
        end
        start("run", { root = root, flags = { file = { rel }, rtp = ctx.flags.rtp } })
      end,
    },
    {
      path = { "last" },
      desc = "Repeat the last run",
      run = function()
        local last = M.last_run
        if not last then
          notify().warn("there is no earlier run in this session")
          return
        end
        start(last.sub, last.opts)
      end,
    },
    {
      path = { "list" },
      desc = "List the spec files that would run, run nothing",
      args = { { name = "root", type = "DIR", optional = true } },
      flags = run_flags(),
      run = function(ctx)
        start("list", { root = M.resolve_root(ctx.args.root), flags = M.child_flags(ctx.flags) })
      end,
    },
    {
      path = { "init" },
      desc = "Generate .testing.lua, TESTS/minimal_init.lua, scripts/test.sh and a CI job (never overwrites)",
      args = { { name = "root", type = "DIR", optional = true } },
      flags = {
        {
          name = "force",
          bool = true,
          desc = "Replace existing files instead of keeping them (not hooks)",
        },
        {
          name = "plugin",
          type = "STRING",
          desc = "Plugin name for the generated files (default: detected)",
        },
        {
          name = "hooks",
          bool = true,
          desc = "Generate the git and agent hook scripts instead of the setup",
        },
      },
      run = function(ctx)
        local root = ctx.args.root and abs(ctx.args.root) or abs(vim.fn.getcwd())
        local result = require("testing.scaffold").init(
          root,
          { force = ctx.flags.force, plugin = ctx.flags.plugin, hooks = ctx.flags.hooks }
        )
        local lines = {}
        if #result.created > 0 then
          lines[#lines + 1] = "created: " .. table.concat(result.created, ", ")
        end
        if #result.replaced > 0 then
          lines[#lines + 1] = "replaced (--force): " .. table.concat(result.replaced, ", ")
        end
        if #result.skipped > 0 then
          -- `--force` never reaches a hook file (a hook of yours is not ours to replace): do not promise it
          lines[#lines + 1] = (
            ctx.flags.hooks and "kept (exists; --force does not apply to hooks): "
            or "kept (exists; --force replaces): "
          ) .. table.concat(result.skipped, ", ")
        end
        for _, e in ipairs(result.errors) do
          lines[#lines + 1] = "error: " .. e
        end
        if ctx.flags.hooks and #result.created > 0 and #result.errors == 0 then
          vim.list_extend(lines, require("testing.scaffold").hook_next_steps())
        end
        if #lines == 0 then
          lines[1] = "nothing to do"
        end
        local text = ("testing init %s\n%s"):format(root, table.concat(lines, "\n"))
        if #result.errors > 0 then
          notify().error(text)
        else
          notify().info(text)
        end
      end,
    },
    {
      path = { "migrate" },
      desc = "Plan the move of a plugin repo to testing.nvim (dry-run; `apply` writes into a clean git tree)",
      args = {
        { name = "mode", type = M.TYPE_MIGRATE, optional = true },
        { name = "root", type = "DIR", optional = true },
      },
      flags = {
        {
          name = "fleet-root",
          type = "DIR",
          desc = "Folder of the *.nvim repos to resolve requires against",
        },
      },
      run = M.migrate,
    },
    {
      path = { "conformance" },
      desc = "Run the conformance checks K1..K15 on the project (report only unless --gate)",
      args = { { name = "root", type = "DIR", optional = true } },
      flags = {
        {
          name = "gate",
          bool = true,
          desc = "Exit 1 when a check fails instead of only reporting",
        },
        {
          name = "only",
          type = "STRING",
          desc = "Run only these checks (ids like K1,K3)",
        },
        {
          name = "skip",
          type = "STRING",
          desc = "Leave out these checks (ids like K10)",
        },
        {
          name = "bridge",
          bool = true,
          desc = "Also compare with rules.nvim's own rule check, if installed",
        },
        {
          name = "markdown",
          bool = true,
          desc = "Print the report as Markdown instead of terminal lines",
        },
      },
      run = function(ctx)
        start("conformance", {
          root = M.resolve_root(ctx.args.root),
          flags = {
            raw = raw_args(ctx.flags, {
              bool = { "gate", "bridge", "markdown" },
              value = { "only", "skip" },
            }),
          },
        })
      end,
    },
    {
      path = { "surface" },
      desc = "List the plugin's keymaps, commands and autocmds and how much the specs exercised",
      args = { { name = "root", type = "DIR", optional = true } },
      flags = {
        {
          name = "from",
          type = "FILE",
          desc = "Read what the specs exercised from this Result-IR file",
        },
        {
          name = "threshold",
          type = "STRING",
          desc = "Fail when the exercised ratio is below 0..1 (or kind=0..1)",
        },
        {
          name = "markdown",
          bool = true,
          desc = "Print the report as Markdown instead of a text table",
        },
      },
      run = function(ctx)
        start("surface", {
          root = M.resolve_root(ctx.args.root),
          flags = {
            raw = raw_args(ctx.flags, {
              bool = { "markdown" },
              value = { "from", "threshold" },
            }),
          },
        })
      end,
    },
    {
      path = { "budget" },
      desc = "Measure the performance budgets and compare them with the baseline",
      args = { { name = "root", type = "DIR", optional = true } },
      flags = {
        {
          name = "update",
          bool = true,
          desc = "Write the measured values as the new baseline",
        },
        {
          name = "allow-new",
          bool = true,
          desc = "Accept measured cases that have no baseline entry yet",
        },
        {
          name = "factor",
          type = "STRING",
          desc = "Allowed slowdown against the baseline as a factor (1-1000)",
        },
      },
      run = function(ctx)
        start("budget", {
          root = M.resolve_root(ctx.args.root),
          flags = {
            raw = raw_args(ctx.flags, { bool = { "update", "allow-new" }, value = { "factor" } }),
          },
        })
      end,
    },
    {
      path = { "cache", "stats" },
      desc = "Show the size and age of the result cache of the project",
      args = { { name = "root", type = "DIR", optional = true } },
      run = function(ctx)
        local root = M.resolve_root(ctx.args.root)
        local s = require("testing.cache").stats({ root = root })
        notify().info(
          ("result cache of %s: %d entr%s, %.1f KB (%s)"):format(
            root,
            s.entries,
            s.entries == 1 and "y" or "ies",
            s.bytes / 1024,
            s.dir
          )
        )
      end,
    },
    {
      path = { "cache", "clear" },
      desc = "Delete the result cache of the project (it is regenerable: costs time, never correctness)",
      args = { { name = "root", type = "DIR", optional = true } },
      run = function(ctx)
        local root = M.resolve_root(ctx.args.root)
        local n = require("testing.cache").clear({ root = root })
        notify().info(
          ("result cache of %s cleared: %d entr%s removed"):format(root, n, n == 1 and "y" or "ies")
        )
      end,
    },
    {
      path = { "health" },
      desc = "Run :checkhealth testing",
      run = function()
        vim.cmd("checkhealth testing")
      end,
    },
    {
      path = { "config" },
      desc = "Show the effective configuration",
      run = function()
        notify().info(vim.inspect(require("testing.config").get()))
      end,
    },
    {
      path = { "doctor" },
      desc = "Show the project's resolved configuration and the dependency report",
      args = { { name = "root", type = "DIR", optional = true } },
      run = function(ctx)
        start("doctor", { root = M.resolve_root(ctx.args.root) })
      end,
    },
  }
end

---Register the argument types (live completion) with the composer.
---@param composer table
local function register_types(composer)
  local prefix = require("lib.nvim.bindings.usercmd.composer.argtypes").prefix
  composer.register_type(M.TYPE_REPORTER, {
    validate = function(raw)
      local names = require("testing.args").REPORTERS
      if vim.tbl_contains(names, raw) then
        return true, raw, nil
      end
      return false, nil, ("expected one of %s"):format(table.concat(names, "|"))
    end,
    complete = function(lead)
      return prefix(require("testing.args").REPORTERS, lead)
    end,
  })
  composer.register_type(M.TYPE_MIGRATE, {
    validate = function(raw)
      if raw == "" then
        return false, nil, "expected dry-run, apply or a directory"
      end
      return true, raw, nil
    end,
    complete = function(lead)
      local out = prefix(require("testing.migrate").MODES, lead)
      vim.list_extend(out, vim.fn.getcompletion(lead, "dir"))
      return out
    end,
  })
  composer.register_type(M.TYPE_SPEC, {
    validate = function(raw)
      if raw == "" then
        return false, nil, "expected a part of a spec file name"
      end
      return true, raw, nil
    end,
    complete = function(lead)
      local ok, files = pcall(M.spec_files, M.resolve_root())
      if not ok then
        return {}
      end
      -- A substring is what `--file` means, so offer the whole path for any part the user typed.
      local out = {}
      for _, f in ipairs(files) do
        if lead == "" or f:find(lead, 1, true) then
          out[#out + 1] = f
        end
      end
      return out
    end,
  })
end

---Register `:Testing`. Safe to call twice.
---@return boolean ok False when lib.nvim is missing; the error is shown once.
function M.register()
  -- the flag alone would lie once the command was removed again (a spec cleaning up after `setup()`)
  if registered and vim.fn.exists(":Testing") == 2 then
    return true
  end
  local ok, err = pcall(function()
    local composer = require("lib.nvim.bindings.usercmd.composer")
    register_types(composer)
    composer.verb("Testing", {
      desc = "testing.nvim: run, file, last, list, init, migrate, conformance, surface, budget, cache, health, config, doctor",
      default = function()
        M.run_all({ args = {}, flags = {} })
      end,
      routes = M.routes(),
    })
  end)
  if not ok then
    -- lib.nvim itself is what failed to load, so its notifier is not an option here.
    vim.schedule(function()
      vim.notify(
        ("[testing] :Testing is unavailable: %s"):format(tostring(err)),
        vim.log.levels.WARN
      )
    end)
    return false
  end
  registered = true
  return true
end

return M
