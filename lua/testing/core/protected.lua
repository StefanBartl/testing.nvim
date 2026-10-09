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
---   * the harness (`with_patched` pcalls its callback and re-raises) and the runner (`safe_call`, the
---     busted hooks) are transparent: the error goes on to the next protected call;
---   * "the spec wrote it" means the code that CALLED `pcall` is in the spec's own file (the lowest Lua
---     frame above the entry point that is not part of the runner);
---   * any other protected call is code UNDER TEST that protects a callback (`pcall(cb)` in an event
---     emitter, `safe_call`) or a helper of the spec: it swallows the error. A raise there would make a
---     failed check vanish and the case pass, so the check is recorded instead, as it is everywhere else.
---
--- One limit, from LuaJIT: a `pcall` in tail position (`return pcall(cb)`) replaces the frame of the function
--- that wrote it, and `debug.getinfo` has no `istailcall` to tell. Such a `pcall` looks like a call of the code
--- that called the function: in a plugin's helper it is taken for the spec's own, and a failed check inside the
--- callback raises into the helper's `pcall` (the spec's `return pcall(...)` is recognised, since the frame
--- below it is the spec's). Write `local ok = pcall(cb); return ok` where a failed check must not be lost.

local M = {}

-- the real protected calls: a frame running one of these is a `pcall` that the code below it wrote
local pcall_fn, xpcall_fn = pcall, xpcall

-- deeper stacks than this are not searched (a runaway recursion in a spec must not make a failed check slow)
local MAX_LEVEL = 200

---Number of stack levels from the caller of this function up to the bottom (the caller is level 1).
---@return integer
function M.stack_size()
  local n = 1
  while debug.getinfo(n + 1, "l") do
    n = n + 1
  end
  return n
end

---Height (frames below it) of the function that calls this one. Call it first thing in the function
---that starts the spec; `inside` compares the heights of the protected calls with it.
---@return integer
function M.entry_height()
  -- `stack_size()` counts from this function (level 1); the caller is level 2, so its height is size - 2
  return M.stack_size() - 2
end

---@param s string
---@return string
local function slashes(s)
  return (s:gsub("\\", "/"))
end

---Is this chunk part of the runner (`lua/testing/...`)? Its frames are never the spec.
---@param source string `debug.getinfo(...).source`
---@return boolean
local function is_runner(source)
  return slashes(source):find("lua/testing/", 1, true) ~= nil
end

---Is the caller running inside a protected call that the SPEC wrote above the entry point?
---@param entry_height integer|nil `entry_height()` of the function that started the spec; nil = unknown (no)
---@param harness_file? string File of the project's harness (slashes): its own protected calls are transparent.
---@return boolean
function M.inside(entry_height, harness_file)
  if not entry_height then
    return false
  end
  local total = M.stack_size()
  -- chunk of the code that called the innermost protected call that is not transparent
  ---@type string|nil
  local catcher
  -- chunk of the lowest frame of the spec's own code, at or above the entry point (the case body is the
  -- spec itself in a unit test of the kernel, the dialect's closure below it otherwise)
  ---@type string|nil
  local spec_source
  local level = 2
  while level < MAX_LEVEL do
    local info = debug.getinfo(level, "fS")
    if not info or total - level < entry_height then
      break
    end
    if total - level > entry_height and (info.func == pcall_fn or info.func == xpcall_fn) then
      local caller = debug.getinfo(level + 1, "S")
      if caller and caller.what ~= "C" and not catcher then
        local source = caller.source
        local file = slashes(source:sub(1, 1) == "@" and source:sub(2) or caller.short_src)
        if file ~= harness_file and not is_runner(source) then
          catcher = source
        end
      end
    elseif info.what ~= "C" and not is_runner(info.source) then
      -- frames come from the assertion down to the entry point: the last one seen is the lowest
      spec_source = info.source
    end
    level = level + 1
  end
  return catcher ~= nil and catcher == spec_source
end

return M
