---@module 'testing.guard.prompt'
---@brief Blocking prompts: scripted answers or an immediate error with the spec's stack, never a hang.
---@description
--- Replaced while a case is open: `vim.fn.input` / `inputdialog` / `inputsecret` / `inputlist` /
--- `confirm` / `getchar` / `getcharstr` (blocking forms only; `getchar(0)` and `getchar(1)` poll and
--- pass through) and `vim.ui.input` / `vim.ui.select`.
---
--- Answers (`handle:answer_prompts{ ... }`):
---   * `input`   string for `input()` / `vim.ui.input`
---   * `select`  index for `vim.ui.select` / `inputlist()` (or, for `vim.ui.select`, an item that
---               equals one of the items)
---   * `confirm` choice number for `confirm()`
---   * `getchar` key (string for `getcharstr`, number for `getchar`)
---
--- A scalar answers every prompt of its kind, a list is consumed in order (an exhausted list is "no
--- answer"), a function is called with the prompt arguments and returns the answer. `CANCEL` stands
--- for "the user cancelled". Without an answer the call raises an error that names the prompt and
--- carries the stack, and the finding `prompt.unanswered` is recorded (also when the spec `pcall`s
--- the error). Every prompt is written to the ledger kind `prompts`.
---
--- The dialogs of the kit (`lib.nvim.ui.kit`, which `ui.kit` re-exports) are answered the same way,
--- through the kit's dialog hook, and no window opens:
---   * `confirm` (also for `kit.ask`) choice index or label; for a plain question `true`/`false` or
---               1 (yes) / 2 (no)
---   * `input`   the text the user would type
---   * `select`  index or item
---   * `form`    the keyed table of values of a `kit.form` / `kit.sheet` (a list of such tables is a queue)
--- The hook is set when a case starts, for a kit that is loaded by then and has `set_dialog_hook`, and only when
--- `guards.prompt.kit = true` (off by default: a spec that opens a real kit dialog on purpose would be refused).
---
--- Limits: `:call input()` and other Vimscript callers do not go through these Lua wrappers (the
--- child runner's null stdin ends such a prompt); prompts of plugins that call
--- `vim.api.nvim_input`-style key loops are not seen.

local M = {}

local KEYS = { input = true, select = true, confirm = true, getchar = true, form = true }

--- The answer kind of each kit dialog kind.
local KIT_ANSWER = {
  confirm = "confirm",
  ask = "confirm",
  input = "input",
  select = "select",
  form = "form",
  sheet = "form",
}

---@class Testing.Guard.Prompt
---@field h Testing.Guard.Handle
---@field cfg table
---@field answers table<string, table>
local G = {}
G.__index = G

---@param h Testing.Guard.Handle
---@param cfg table
---@return Testing.Guard.Prompt
function M.new(h, cfg)
  return setmetatable({ h = h, cfg = cfg, answers = {} }, G)
end

---Replace the answers (`nil` clears them).
---@param map? table
function G:set_answers(map)
  self.answers = {}
  if map == nil then
    return
  end
  for k, v in pairs(map) do
    if not KEYS[k] then
      error(
        ("testing.guard: unknown prompt answer %q (known: input, select, confirm, getchar, form)"):format(
          tostring(k)
        ),
        3
      )
    end
    -- a list is a queue; for `form` a keyed table is the one answer of every form (a list of them is a queue)
    local queue = type(v) == "table"
      and v ~= require("testing.guard").CANCEL
      and (k ~= "form" or #v > 0)
    self.answers[k] = queue and { queue = vim.deepcopy(v) } or { value = v }
  end
end

---@alias Testing.Guard.Answer { found: boolean, value: any }

---@param kind string
---@param ... any prompt arguments (for function answers)
---@return boolean found
---@return any value
function G:answer(kind, ...)
  local a = self.answers[kind]
  if not a then
    return false
  end
  if a.queue then
    if #a.queue == 0 then
      return false
    end
    return true, table.remove(a.queue, 1)
  end
  if type(a.value) == "function" then
    return true, a.value(...)
  end
  return true, a.value
end

---@param self Testing.Guard.Prompt
---@param api string
---@param text any
---@param kind string
local function refuse(self, api, text, kind)
  local h = self.h
  local desc = ("%s(%s)"):format(api, text ~= nil and vim.inspect(text):gsub("\n", " ") or "")
  h:log("prompts", desc .. " [unanswered]", { blocked = true })
  local stack = h:stack(3)
  local msg = ("%s asked a prompt nobody answered: %s. Answer it with answer_prompts{ %s = ... } or avoid it."):format(
    h:label(),
    desc,
    kind
  )
  local finding =
    h:finding("prompt", "prompt.unanswered", msg, { mode = self.cfg.mode, stack = stack })
  -- `warn` reports and answers like a cancelled prompt (nothing may wait for a key in a headless run);
  -- `error` (or `warn` promoted by `--strict`) makes the case fail on the spot
  if finding == nil or finding.severity == "error" then
    error("testing.guard: " .. h.redact(msg) .. "\n" .. h.redact(stack), 0)
  end
end

---@param text any
---@return string
local function prompt_text(text)
  if type(text) == "table" then
    text = text.prompt or text[1]
  end
  return tostring(text or "")
end

function G:install()
  local h, g = self.h, self
  local CANCEL = require("testing.guard").CANCEL

  local function wrap_fn(name, kind, build_default)
    h.patcher:wrap(vim.fn, name, function(orig)
      return function(...)
        if not h:is_active() then
          return orig(...)
        end
        -- polling forms never block
        if (name == "getchar" or name == "getcharstr") and (...) ~= nil and (...) ~= -1 then
          return orig(...)
        end
        -- a key is already waiting (`nvim_feedkeys` before `getchar()`): the call returns at once and
        -- nobody is asked anything. `getchar(1)` only peeks (0 / "" when nothing is typed ahead).
        if name == "getchar" or name == "getcharstr" then
          local function typed_ahead()
            local pok, pending = pcall(orig, 1)
            return pok and pending ~= nil and pending ~= 0 and pending ~= ""
          end
          if typed_ahead() then
            return orig(...)
          end
          -- nothing yet: a picker test feeds its key from a timer or an autocmd while `getchar()` waits.
          -- The editor's event loop runs for a short while (`getchar_wait_ms`); a key that arrives is the
          -- spec's answer, no key means a prompt nobody answers
          local wait = tonumber(g.cfg.getchar_wait_ms) or 0
          if wait > 0 then
            pcall(vim.wait, wait, typed_ahead, 10)
            if typed_ahead() then
              return orig(...)
            end
          end
        end
        local args = { ... }
        local text = prompt_text(args[1])
        local found, value = g:answer(kind, unpack(args))
        if not found then
          refuse(g, "vim.fn." .. name, text ~= "" and text or nil, kind)
          value = CANCEL
        end
        h:log("prompts", ("vim.fn.%s(%s)"):format(name, vim.inspect(text)))
        if value == CANCEL then
          return build_default(true)
        end
        return value
      end
    end, "vim.fn." .. name)
  end
  wrap_fn("input", "input", function()
    return ""
  end)
  wrap_fn("inputdialog", "input", function()
    return ""
  end)
  wrap_fn("inputsecret", "input", function()
    return ""
  end)
  wrap_fn("inputlist", "select", function()
    return 0
  end)
  wrap_fn("confirm", "confirm", function()
    return 0
  end)
  wrap_fn("getchar", "getchar", function()
    return 27
  end)
  wrap_fn("getcharstr", "getchar", function()
    return "\27"
  end)

  if vim.ui then
    h.patcher:wrap(vim.ui, "input", function(orig)
      return function(opts, on_confirm)
        if not h:is_active() then
          return orig(opts, on_confirm)
        end
        local text = prompt_text(opts)
        local found, value = g:answer("input", opts)
        if not found then
          refuse(g, "vim.ui.input", text ~= "" and text or nil, "input")
          value = CANCEL
        end
        h:log("prompts", ("vim.ui.input(%s)"):format(vim.inspect(text)))
        if value == CANCEL then
          value = nil
        end
        on_confirm(value)
      end
    end, "vim.ui.input")
    h.patcher:wrap(vim.ui, "select", function(orig)
      return function(items, opts, on_choice)
        if not h:is_active() then
          return orig(items, opts, on_choice)
        end
        local text = prompt_text(opts)
        local found, value = g:answer("select", items, opts)
        if not found then
          refuse(g, "vim.ui.select", text ~= "" and text or nil, "select")
          value = CANCEL
        end
        h:log("prompts", ("vim.ui.select(%s)"):format(vim.inspect(text)))
        if value == CANCEL then
          return on_choice(nil, nil)
        end
        local idx
        if type(value) == "number" then
          idx = value
        else
          for i, item in ipairs(items) do
            if item == value then
              idx = i
              break
            end
          end
        end
        if idx and items[idx] ~= nil then
          return on_choice(items[idx], idx)
        end
        return on_choice(nil, nil)
      end
    end, "vim.ui.select")
  end

  self:hook_kit()
end

---Set the dialog hook of the kit, when one is loaded that has it. Inert while no case is open.
function G:hook_kit()
  if self.cfg.kit ~= true then
    return
  end
  local kit = package.loaded["lib.nvim.ui.kit"]
  if self.kit == kit or type(kit) ~= "table" or type(kit.set_dialog_hook) ~= "function" then
    return
  end
  local h, g = self.h, self
  local CANCEL = require("testing.guard").CANCEL
  self.kit = kit
  self.previous_hook = type(kit.get_dialog_hook) == "function" and kit.get_dialog_hook() or nil
  self.kit_hook = function(kind, opts)
    local answer_kind = KIT_ANSWER[kind]
    if not answer_kind or not h:is_active() then
      return false
    end
    opts = opts or {}
    local text = prompt_text(opts.question or opts.prompt or opts.message or opts.title)
    local found, value = g:answer(answer_kind, opts)
    if not found then
      refuse(g, "kit." .. kind, text ~= "" and text or nil, answer_kind)
      value = CANCEL
    end
    h:log("prompts", ("kit.%s(%s)"):format(kind, vim.inspect(text)))
    if value == CANCEL then
      value = nil
    end
    return true, value
  end
  kit.set_dialog_hook(self.kit_hook)
end

---Take the dialog hook out again (only when it is still ours).
function G:uninstall()
  local kit = self.kit
  self.kit = nil
  if
    type(kit) == "table"
    and type(kit.get_dialog_hook) == "function"
    and kit.get_dialog_hook() == self.kit_hook
  then
    kit.set_dialog_hook(self.previous_hook)
  end
  self.kit_hook, self.previous_hook = nil, nil
end

function G:begin()
  -- answers belong to a case: the next case starts without
  self.answers = {}
  -- a kit that was loaded after the guard was installed gets its hook now
  self:hook_kit()
end

return M
