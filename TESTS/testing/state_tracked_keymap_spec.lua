---@diagnostic disable: undefined-field, need-check-nil, param-type-mismatch, missing-fields
-- TESTS/testing/state_tracked_keymap_spec.lua -- surface tracking wraps the callback of every Lua keymap that goes
-- through `nvim_set_keymap`. The state guard must not mistake that for a change: putting the SAME function back
-- (a restore, a plugin that re-sets the editor's default it replaced) is not "replaces keymap". Found in ai.nvim,
-- where nvim's default insert-mode <Tab> is re-set during a case and the tracked suite went red for it.

return function(H)
  local ok = H.ok
  local state = require("testing.guard.state")
  local track = require("testing.surface.track")

  local cfg = {
    categories = { keymaps = "error" },
    max_buffers_scanned = 4,
    ignore_keymaps = {},
  }
  local h = { notes = {} }

  local function keymap_diff(before, after)
    local g = state.new(h, cfg)
    return g:diff({ keymaps = before }, { keymaps = after }).keymaps or {}
  end

  local function capture()
    return state.new(h, cfg):capture().keymaps
  end

  local lhs = "<Plug>(testing-state-tracked)"
  -- (defined from a chunk of its own: the layer leaves handlers that come from a spec file unwrapped)
  local function plugin_fn()
    return assert(load("return function() end", "=plugin"))()
  end
  local original, other = plugin_fn(), plugin_fn()
  local function set(cb)
    vim.api.nvim_set_keymap("n", lhs, "", { callback = cb, desc = "tracked keymap probe" })
  end

  -- the editor's default (or any keymap that exists before tracking goes in) holds the plain function ...
  set(original)
  local before = capture()
  local handle = track.install({ rewrap = false })
  local pok, perr = pcall(function()
    -- ... and the same function set again after the layer is installed goes through the wrapper: another function
    -- object (a restore, a plugin that re-sets the default it replaced), the same keymap
    set(original)
    local same = keymap_diff(before, capture())
    ok(
      #same == 0,
      "re-setting the same callback under tracking is not a change: " .. vim.inspect(same)
    )

    -- control: another function really is a replacement
    set(other)
    local changed = keymap_diff(before, capture())
    ok(
      #changed == 1 and changed[1].op == "changed",
      "a different callback is still reported as replaced: " .. vim.inspect(changed)
    )
  end)
  -- a stubbed or half-loaded surface module must not make the comparison throw (and so hide a real replacement)
  local saved = package.loaded["testing.surface.track"]
  package.loaded["testing.surface.track"] = true
  local sok, serr = pcall(function()
    set(other)
    local stubbed = keymap_diff(before, capture())
    ok(
      #stubbed == 1 and stubbed[1].op == "changed",
      "a non-table surface module still lets a replacement be reported: " .. vim.inspect(stubbed)
    )
  end)
  package.loaded["testing.surface.track"] = saved
  pcall(vim.api.nvim_del_keymap, "n", lhs)
  handle:uninstall()
  if not sok then
    error(serr, 0)
  end
  if not pok then
    error(perr, 0)
  end
end
