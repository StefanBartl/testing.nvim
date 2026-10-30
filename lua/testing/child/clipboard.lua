---@module 'testing.child.clipboard'
---@brief An in-memory `+`/`*` clipboard for a throwaway editor: a spec that writes `+` never reaches the system clipboard.
---@description
--- A child starts with `-u NORC` / `--clean` and no `g:clipboard`. On the first access of `+` or `*` the
--- editor probes for a clipboard tool and finds one on every developer machine (`win32yank.exe` ships
--- with the Windows build; `pbcopy`, `xclip`, `wl-copy` elsewhere): from then on every `setreg("+", ...)`,
--- `"+y`, `:%y+` and `lib.nvim.cross.copy_to_clipboard` of a spec overwrites the USER'S clipboard. Seen
--- on 2026-10-30, on two machines: a marker of lib.nvim's copy_to_clipboard_spec came out of Ctrl+V in a
--- browser while suites were running in the background.
---
--- `install()` sets `vim.g.clipboard` to a provider that keeps the lines in this process (`:h g:clipboard`;
--- the pattern a few minimal inits of the fleet carried on their own). It runs BEFORE the project's minit
--- in every child (`testing.child.boot`, `testing.child.rpc_init`, which a warm pool member starts with too)
--- and before the minit of a headless in-process run (`testing.run.project`), so a minit that sets
--- `g:clipboard` itself still wins. It refuses, and says why:
---
---   * an editor with a UI: `:Testing` in-process runs in the user's own editor and must not take their
---     clipboard away;
---   * an editor whose `g:clipboard` is set: the project or the user decided;
---   * an editor whose provider already ran (`g:loaded_clipboard_provider`): the editor read `g:clipboard`
---     once and would not look at it again.
---
--- `provider()` is pure (a fresh store per call); `install()` makes the one assignment and reads nothing
--- from the system.

local M = {}

---The `name` of the provider: what `vim.g.clipboard.name` answers in a child.
M.NAME = "testing-fake-clipboard"

---A `g:clipboard` provider whose `+` and `*` are two stores in this process. `copy` receives the lines and
---the register type the editor hands a provider; `paste` answers `[lines, regtype]`, so a linewise or
---blockwise yank comes back as it went in.
---@return table provider
function M.provider()
  ---@type table<string, { [1]: string[], [2]: string }>
  local store = { ["+"] = { {}, "v" }, ["*"] = { {}, "v" } }
  local copy, paste = {}, {}
  for _, reg in ipairs({ "+", "*" }) do
    copy[reg] = function(lines, regtype)
      store[reg] = {
        vim.deepcopy(type(lines) == "table" and lines or {}),
        type(regtype) == "string" and regtype or "v",
      }
    end
    paste[reg] = function()
      return { vim.deepcopy(store[reg][1]), store[reg][2] }
    end
  end
  return { name = M.NAME, copy = copy, paste = paste, cache_enabled = 0 }
end

---Install the provider in this editor, when it is a throwaway one and nobody decided before.
---@return boolean installed
---@return string|nil why When not installed: the reason.
function M.install()
  if vim.g.clipboard ~= nil then
    return false, "g:clipboard is set"
  end
  if vim.g.loaded_clipboard_provider ~= nil then
    return false, "the clipboard provider already ran"
  end
  if #vim.api.nvim_list_uis() > 0 then
    return false, "the editor has a UI"
  end
  vim.g.clipboard = M.provider()
  return true, nil
end

return M
