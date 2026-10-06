---@module 'testing.guard.patch'
---@brief Restorable monkeypatches: the one place where the guards replace functions.
---@description
--- A `Patcher` records every replacement (`tbl[key]`) and undoes them in reverse order. A patch is
--- only undone when the slot still holds OUR wrapper: if somebody wrapped it again on top of us, we
--- leave their wrapper alone and remember the slot in `unrestored` (a wrapper that stays is a
--- finding of the harness itself, never a silent overwrite).
---
--- Slots that are lazily created by a metatable (`vim.fn.<name>`) are put back to `nil` when they
--- were not materialized before, so the lazy accessor works again after `restore`.

local M = {}

---@class Testing.Guard.Patcher
---@field private stack { tbl: table, key: any, orig: any, wrapper: any, raw: boolean, label: string }[]
---@field unrestored string[] Labels of slots that could not be put back.
local Patcher = {}
Patcher.__index = Patcher

---@return Testing.Guard.Patcher
function M.new()
  return setmetatable({ stack = {}, unrestored = {} }, Patcher)
end

---Replace `tbl[key]` by `make(original)`. Nothing happens (and `nil` is returned) when the slot is
---empty: an API that does not exist on this Neovim version cannot be wrapped.
---@param tbl table
---@param key any
---@param make fun(orig: function): function
---@param label? string Name for messages (`io.open`); default the key.
---@return function|nil original
function Patcher:wrap(tbl, key, make, label)
  local ok, orig = pcall(function()
    return tbl[key]
  end)
  if not ok or type(orig) ~= "function" then
    return nil
  end
  local wrapper = make(orig)
  self.stack[#self.stack + 1] = {
    tbl = tbl,
    key = key,
    orig = orig,
    wrapper = wrapper,
    raw = rawget(tbl, key) ~= nil,
    label = label or tostring(key),
  }
  tbl[key] = wrapper
  return orig
end

---Number of active patches.
---@return integer
function Patcher:count()
  return #self.stack
end

---Undo every patch, newest first. Idempotent.
---@return string[] unrestored
function Patcher:restore()
  for i = #self.stack, 1, -1 do
    local p = self.stack[i]
    local cur_ok, cur = pcall(function()
      return p.tbl[p.key]
    end)
    if cur_ok and cur == p.wrapper then
      if p.raw then
        p.tbl[p.key] = p.orig
      else
        p.tbl[p.key] = nil
      end
    else
      self.unrestored[#self.unrestored + 1] = p.label
    end
    self.stack[i] = nil
  end
  return self.unrestored
end

return M
