---@diagnostic disable: undefined-field, need-check-nil, redundant-parameter
-- TESTS/testing/guard_uninstall_spec.lua -- the teardown of the guard layer tells the truth: a guard whose
-- uninstall raises is named (not swallowed), the guards come down in the reverse of the install order,
-- a patch that cannot be written back does not keep the others (or the handle) installed, and a stub
-- layered on top of a wrapper is a leak the warm pool hears about.

return function(H)
  local ok, eq = H.ok, H.eq
  local guard = require("testing.guard")
  local config = require("testing.guard.config")
  local patch = require("testing.guard.patch")

  local function only(names)
    local g = {}
    for _, n in ipairs(config.ORDER) do
      g[n] = "off"
    end
    for _, n in ipairs(names) do
      g[n] = { mode = "error" }
    end
    return { guards = g }
  end

  -- ---------------------------------------------------------------- Patcher: a write that raises
  local store = { f = function() end }
  local locked = false
  local proxy = setmetatable({}, {
    __index = function(_, k)
      return store[k]
    end,
    __newindex = function(_, k, v)
      if locked then
        error("table is locked")
      end
      store[k] = v
    end,
  })
  local p = patch.new()
  local plain = { g = function() end }
  local g_orig = plain.g
  p:wrap(plain, "g", function(o)
    return function(...)
      return o(...)
    end
  end, "plain.g")
  p:wrap(proxy, "f", function(o)
    return function(...)
      return o(...)
    end
  end, "proxy.f")
  locked = true
  local pok, left = pcall(p.restore, p)
  locked = false
  ok(pok, "restore does not raise when a slot cannot be written")
  eq(plain.g, g_orig, "the other patches are still undone")
  eq(#left, 1, "the slot that could not be written back is named")
  ok(left[1]:find("proxy.f", 1, true) and left[1]:find("locked", 1, true), left[1])
  eq(p:count(), 0, "and no patch stays on the stack")

  -- ---------------------------------------------------------------- Handle: order, errors, installed flag
  -- (the dogfood run has its own guard layer installed: count relative to it)
  local live0 = guard.live_count()
  local h = guard.install(only({ "fs", "prompt", "deprecation" }))
  local order = {}
  for _, name in ipairs({ "fs", "prompt", "deprecation" }) do
    local g = h.guards[name]
    local real = g.uninstall
    g.uninstall = function(self)
      order[#order + 1] = name
      if name == "prompt" then
        error("boom in " .. name)
      end
      if real then
        return real(self)
      end
    end
  end
  local got = h:uninstall()
  local expected = {}
  for i = #config.ORDER, 1, -1 do
    local n = config.ORDER[i]
    if n == "fs" or n == "prompt" or n == "deprecation" then
      expected[#expected + 1] = n
    end
  end
  eq(order, expected, "the guards come down in the reverse of the install order")
  eq(#got, 1, "the failing teardown is reported")
  ok(
    got[1]:find("prompt guard failed to uninstall", 1, true) and got[1]:find("boom", 1, true),
    got[1]
  )
  eq(h.installed, false, "the handle is uninstalled although a teardown raised")
  eq(guard.live_count(), live0, "and no longer live")
  guard.take_unrestored()

  -- ---------------------------------------------------------------- a stub on top of a wrapper
  local real_open = io.open
  h = guard.install(only({ "fs" }))
  local wrapped = io.open
  ok(wrapped ~= real_open, "the fs guard wraps io.open")
  local stub = function(...)
    return wrapped(...)
  end
  rawset(io, "open", stub) -- a spec that stubbed io.open on top and never restored it
  local labels = h:uninstall()
  eq(io.open, stub, "their stub is left alone")
  rawset(io, "open", real_open)
  ok(
    #labels >= 1 and table.concat(labels, ","):find("io.open", 1, true),
    "the slot is named: " .. vim.inspect(labels)
  )
  local taken = guard.take_unrestored()
  ok(
    table.concat(taken, ","):find("io.open", 1, true),
    "the pool can ask what was left: " .. vim.inspect(taken)
  )
  eq(guard.take_unrestored(), {}, "and asking forgets")
end
