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
--- So a failed check raises when a `pcall` / `xpcall` that the spec wrote is on the stack between the
--- assertion and the point where the case body was entered. Protected calls of the harness itself
--- (`with_patched` pcalls its callback) and of the runner (below the entry point) do not count: the
--- caller of such a `pcall` is not a frame of the spec.

local M = {}

-- the real protected calls: a frame running one of these is a `pcall` that the code below it wrote
local pcall_fn, xpcall_fn = pcall, xpcall

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

---Is the caller running inside a protected call that a frame ABOVE the entry point made?
---@param entry_height integer|nil `entry_height()` of the function that started the spec; nil = unknown (no)
---@param harness_file? string File of the project's harness: its own protected calls never count.
---@return boolean
function M.inside(entry_height, harness_file)
  if not entry_height then
    return false
  end
  local total = M.stack_size()
  local level = 2
  while level < 200 do
    local info = debug.getinfo(level, "f")
    if not info or total - level <= entry_height then
      return false
    end
    if info.func == pcall_fn or info.func == xpcall_fn then
      local caller = debug.getinfo(level + 1, "S")
      if caller and caller.what ~= "C" then
        local src = caller.source
        local file = slashes(src:sub(1, 1) == "@" and src:sub(2) or caller.short_src)
        if file ~= harness_file and not file:find("lua/testing/", 1, true) then
          return true
        end
      end
    end
    level = level + 1
  end
  return false
end

return M
