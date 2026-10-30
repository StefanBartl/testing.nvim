---@module 'testing.bindings.trust_prompt'
---@brief Asks once whether to trust a project root a run from the editor was refused for.
---@description
--- The workspace trust gate (`testing.trust`) ends a run in an untrusted root with exit 2 and a message that
--- contains `trust.REFUSED`. From the command line that is the answer; from the editor (`:Testing <cmd>`,
--- `:Testing ci`) the user is asked once instead: yes stores the root (`trust.add`, the same store
--- `testing trust add <root>` writes) and the caller starts the run again, no leaves the refusal as it is.
--- Without a UI (a headless nvim) nobody can answer: no question, the refusal stands.

local M = {}

M.YES = "Trust it and run again"
M.NO = "Do not trust it"

---Seam for specs: is there a UI that can answer?
---@return boolean
function M.interactive()
  return #vim.api.nvim_list_uis() > 0
end

---Seam for specs: the trust context `trust.add` stores with (nil: the default store).
---@type Testing.Trust.Ctx|nil
M.ctx = nil

---Did the child end with the trust gate's refusal?
---@param code integer|nil
---@param stderr string|nil
---@return boolean
function M.refused(code, stderr)
  return code == 2
    and type(stderr) == "string"
    and stderr:find(require("testing.trust").REFUSED, 1, true) ~= nil
end

---Ask whether to trust `root`. `on_answer(true)` after the root was stored, `on_answer(false)` when there is no UI,
---the user said no or cancelled, or storing failed (then with the reason, which is also notified).
---@param root string
---@param on_answer fun(trusted: boolean, err?: string)
function M.ask(root, on_answer)
  if not M.interactive() then
    on_answer(false)
    return
  end
  vim.ui.select({ M.YES, M.NO }, {
    prompt = ("testing: %s is not trusted; running it executes its .testing.lua, TESTS/minimal_init.lua and specs. Trust it?"):format(
      root
    ),
  }, function(choice)
    if choice ~= M.YES then
      on_answer(false)
      return
    end
    local ok, err = require("testing.trust").add(root, M.ctx)
    if not ok then
      require("testing.notify")
        .get()
        .error("testing: cannot trust " .. root .. ": " .. tostring(err))
      on_answer(false, err)
      return
    end
    on_answer(true)
  end)
end

return M
