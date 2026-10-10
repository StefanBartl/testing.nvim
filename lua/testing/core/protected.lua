---@module 'testing.core.protected'
---@brief Is an assertion running inside a protected call that the SPEC wrote?
---@description
--- A spec may ask whether an assertion fails: `pcall(function() H.eq(1, 2, "x") end)`, or
--- `pcall(H.with_patched, t, "k", v, function() H.eq(1, 2) end)` to see that the harness restores state
--- when its body raises. With the project's own runner the failed check raises and the `pcall`
--- answers. Here a failed check is RECORDED and the spec goes on (so all failures of a file are
--- visible); inside a protected call of the spec that would swallow the question: the check would be
--- recorded as a failure of the spec, and the `pcall` would report success.
---
--- So a failed check raises when the protected call that would CATCH the raise is one the spec wrote.
--- That is the innermost `pcall` / `xpcall` between the assertion and the point where the case body was
--- entered, leaving out the ones that only clean up and raise again:
---   * the harness (`with_patched` pcalls its callback and re-raises) and the runner (its modules below
---     `lua/testing/`, the busted hooks) are transparent: the error goes on to the next protected call.
---     The harness is the file `harness.lua` and the files below its directory that define a function of
---     `H` (also one table level down), so a harness split over several files counts, and a function of
---     `H` that is the code under test (`H.sut = require("plugin")`) does not;
---   * "the spec wrote it" means the code that CALLED `pcall` is in the spec's own file (`spec_source`, the
---     chunk the dialect loaded; a case that is started without one, as in a unit test of the kernel, takes
---     the lowest Lua frame above the entry point that is not part of the runner);
---   * any other protected call is code UNDER TEST that protects a callback (`pcall(cb)` in an event
---     emitter, `safe_call`) or a helper of the spec: it may swallow the error. A raise there would make a
---     failed check vanish and the case pass, so the check is recorded instead, as it is everywhere else.
---
--- The rule is a guess from the call stack, so it errs towards RECORDING (a spec whose question is not
--- recognised fails loudly) and never towards raising into a protected call it cannot attribute:
---   * only a frame that was called as `pcall` / `xpcall` (a global, a local or an upvalue of that name)
---     counts as the spec's. LuaJIT has no `istailcall`, but the name of the call site shows it:
---     `return pcall(cb)` in a helper leaves a `pcall` frame called `helper`, which is unknown and records,
---     in a plugin's helper and in a spec's own;
---   * a check on another coroutine than the one that started the case always records (stack heights of
---     two threads cannot be compared);
---   * a stack more than `MAX_LEVELS` frames above the entry point is not searched and records;
---   * a check in the MESSAGE HANDLER of an `xpcall` is not a question: the handler runs on top of the frame of
---     `error` / `assert` that is throwing, and an error raised there is not caught by that `xpcall` (LuaJIT
---     answers "error in error handling"). Such a check records. After a runtime error (a nil index, an error
---     of a C function) no `error` frame is left, but the C function itself is: a C frame (an `error()` that
---     `coroutine.wrap` rethrows, a failing `require`) between the check and an `xpcall` records as well. Only a
---     runtime error of Lua code (a nil index) cannot be told from the function: a failed check in that handler
---     is raised and lost, so check the returned message after `xpcall` returned.
---
--- Not covered, by design of the platform: Neovim runs the callbacks of `vim.schedule` (while the spec waits),
--- autocmds, keymaps, timers and the buffer callbacks of typed keys under its own protected call (a C
--- `lua_pcall`, no Lua frame). A check that fails there while a `pcall` of the spec is further out is raised
--- into Neovim's catch, which prints an error and goes on. The `scheduled_error` guard (default `error`) turns
--- these into a red case with the message, not into a check with `file:line`; it reads `:messages`, which keeps
--- 500 entries, so a case that prints about that many more messages afterwards loses the error (a `vim.schedule`
--- callback is remembered by the guard itself). A mock inside the spec that protects a callback and throws the
--- error away cannot be told from a question either. The runner's own questions (`a.error`, `a.no_error`, luassert
--- `has_error`) catch what they are given but count as the runner, which passes errors on, and so does a
--- helper of the harness that catches on purpose (`H.throws(fn)`, a retry or poll helper): a check inside their
--- callback is recorded, the helper sees success and the case ends red, never green. A plugin that lives below the
--- runner's own directory (testing.nvim testing its own modules) counts as the runner. Code is told apart by the
--- name of its chunk (`source`), which is all a frame carries: text that is loaded under the name of the spec
--- file or of the harness (`load(text, "@" .. spec_path)`) is taken for it, and only deliberate code does that.

local M = {}

-- the real protected calls: a frame running one of these is a `pcall` that the code below it wrote
local pcall_fn, xpcall_fn = pcall, xpcall

-- a frame running one of these means an error is being thrown right now: what runs above it is the message
-- handler of an `xpcall`, and an error raised there is not caught by that `xpcall`
local error_fn, assert_fn = error, assert

-- taken now: a spec that stubs `debug.getinfo` or `coroutine.running` must not send the search into a loop
local getinfo = debug.getinfo
local running = coroutine.running

-- more frames than this above the entry point are not searched: the answer is "record". Each frame costs a
-- walk of the stack, so the search is quadratic in this number (about a millisecond at 500).
local MAX_LEVELS = 500

-- a chunk name longer than this is the text of a chunk that was loaded without a name, not a path
local MAX_SOURCE = 4096

---@param s string
---@return string
local function slashes(s)
  return (s:gsub("\\", "/"))
end

---Directory of the runner (`<...>/lua/testing/`), from the name of this very chunk; nil when the chunk
---name does not look like a file below `lua/testing/core/`.
---@type string|nil
local runner_root
do
  local source = getinfo(1, "S").source
  local path = slashes(source:sub(1, 1) == "@" and source:sub(2) or source)
  runner_root = path:match("^(.*/lua/testing/)core/protected%.lua$")
    or path:match("^(lua/testing/)core/protected%.lua$")
end

---Is this chunk part of the runner? Its frames are never the spec and its protected calls only pass on.
---@param source string `debug.getinfo(...).source`
---@return boolean
local function is_runner(source)
  -- a chunk loaded without a name has its whole text as `source`: longer than any path, never a file of the
  -- runner, and not worth a copy per protected call
  if #source > MAX_SOURCE then
    return false
  end
  local path = slashes(source:sub(1, 1) == "@" and source:sub(2) or source)
  if runner_root then
    return path:sub(1, #runner_root) == runner_root
  end
  return path:find("lua/testing/", 1, true) ~= nil
end

---Number of stack levels from this function up to the bottom: this function is level 1, so a function at
---depth D (itself included) that calls it gets D + 1. Found by halving, so a deep stack costs a few walks
---instead of one per level.
---@return integer
function M.stack_size()
  local lo, hi = 1, 2
  while getinfo(hi, "l") do
    lo, hi = hi, hi * 2
  end
  while hi - lo > 1 do
    local mid = math.floor((lo + hi) / 2)
    if getinfo(mid, "l") then
      lo = mid
    else
      hi = mid
    end
  end
  return lo
end

---Where a case body was entered: the height of its frame, the coroutine it runs on and, when the dialect
---knows it, the chunk of the spec file.
---@class Testing.Protected.Entry
---@field height integer Depth of the function that called `entry()`, counted from the bottom, itself included.
---@field thread thread|false `false` is the main thread (LuaJIT answers nil there)
---@field spec? string `source` of the spec file (`"@" .. path`); nil = take the lowest frame of the spec's own code

---The entry point of the function that calls this one. Call it first thing in the function that starts the
---spec; `inside` compares the protected calls above it with it.
---@param spec_source? string `"@" .. path` of the spec file as the dialect loads it
---@return Testing.Protected.Entry
function M.entry(spec_source)
  -- `stack_size()` counts from itself (level 1): this function is level 2 and its caller level 3, so the size
  -- is two above the caller's depth
  return { height = M.stack_size() - 2, thread = running() or false, spec = spec_source }
end

---Is the caller running inside a protected call that the SPEC wrote above the entry point?
---@param entry Testing.Protected.Entry|nil `entry()` of the function that started the spec; nil = unknown (no)
---@param transparent? table<string, true> Chunks (`source`) of the project's harness: their protected calls pass the error on.
---@return boolean
function M.inside(entry, transparent)
  if not entry or (running() or false) ~= entry.thread then
    return false
  end
  local height = entry.height
  -- Beyond the window? One probe tells (a level that does not exist costs a walk of the stack and allocates
  -- nothing), so the size of a very deep stack is not searched just to answer "record".
  if getinfo(height + MAX_LEVELS, "l") then
    return false
  end
  local total = M.stack_size()
  -- level of the frame that entered the case body (this function is level 1)
  local last = total - height
  if last > MAX_LEVELS then
    return false
  end
  -- The innermost protected call above the entry point that is not transparent decides. Only the function of a
  -- level is asked for: the name and the chunk of the caller are needed for the (few) protected calls only,
  -- and the walk stops at the one that decides.
  -- chunk of the code that called it
  ---@type string|nil
  local catcher
  -- level and kind of the protected call that decides
  local catcher_level, catcher_is_xpcall
  for level = 2, last - 1 do
    local info = getinfo(level, "f")
    if not info then
      return false
    end
    local func = info.func
    if func == pcall_fn or func == xpcall_fn then
      local call = getinfo(level, "n")
      local caller = getinfo(level + 1, "S")
      local source = caller and caller.what ~= "C" and caller.source or nil
      -- called from C, as a field or a method, or through another name (an alias, a tail call): nobody
      -- can say who wrote it
      local named = (call.name == "pcall" or call.name == "xpcall")
        and (call.namewhat == "global" or call.namewhat == "local" or call.namewhat == "upvalue")
      if not (source and named) then
        return false
      end
      -- a protected call of the harness or the runner cleans up and raises again: the error goes on
      if not (is_runner(source) or (transparent ~= nil and transparent[source] == true)) then
        catcher, catcher_level, catcher_is_xpcall = source, level, func == xpcall_fn
        break
      end
    elseif func == error_fn or func == assert_fn then
      -- reached from the check before any protected call: the check runs in a message handler, where a raise
      -- is lost
      return false
    end
  end
  if not catcher then
    return false
  end
  if catcher_is_xpcall then
    -- A C function between the check and an `xpcall` (a `coroutine.wrap` that rethrows, `require`, `string.gsub`)
    -- may be the frame an error is being thrown from, and then the check runs in the message handler, where a raise
    -- is lost. A body that calls the check through such a frame is rare, and recording is loud, not green.
    for level = 2, catcher_level - 1 do
      local between = getinfo(level, "fS")
      if not between then
        return false
      end
      local func = between.func
      if between.what == "C" and func ~= pcall_fn and func ~= xpcall_fn then
        return false
      end
    end
  end
  -- chunk of the spec: given by the dialect, else the lowest frame of the spec's own code at or above the
  -- entry point (the case body is the spec itself in a unit test of the kernel)
  local spec_source = entry.spec
  if not spec_source then
    for level = last, 2, -1 do
      local info = getinfo(level, "S")
      if not info then
        return false
      end
      if info.what ~= "C" and not is_runner(info.source) then
        spec_source = info.source
        break
      end
    end
  end
  return catcher == spec_source
end

return M
