---@module 'testing.conformance.catalog'
---@brief The checks K1 .. K15 in order, and the rules of the gates that stay manual.
---@description
--- Guard rail L7 ("gates are specification"): a rule of the gates that can be decided becomes a check,
--- a rule that needs judgement stays manual and is LISTED in the report as `manual`, so that "all green"
--- never reads as "all rules hold". `M.MANUAL` is that list. A rule that a check enforces only in part
--- (K3 for REL-20: the keymaps of the configured setup, not every lhs read from the options) is listed
--- here too, with the part that stays manual in `reason`.

local M = {}

---@type string[]
M.ORDER = {
  "k01_require",
  "k02_idempotent",
  "k03_keymaps_off",
  "k04_keymap_desc",
  "k05_completion",
  "k06_health",
  "k07_soft_deps",
  "k08_deprecation",
  "k09_effects",
  "k10_load_budget",
  "k11_globals",
  "k12_gaps",
  "k13_key_risks",
  "k14_docs",
  "k15_static",
}

---The checks, in order (loaded on first use).
---@return Testing.Conformance.Check[]
function M.checks()
  local out = {}
  for _, name in ipairs(M.ORDER) do
    out[#out + 1] = require("testing.conformance.checks." .. name)
  end
  return out
end

---Check ids as a set.
---@return table<string, boolean>
function M.ids()
  local set = {}
  for i = 1, #M.ORDER do
    set["K" .. i] = true
  end
  return set
end

---@param id string
---@return Testing.Conformance.Check|nil
function M.get(id)
  local n = tonumber(id:match("^K(%d+)$"))
  if not n or not M.ORDER[n] then
    return nil
  end
  return require("testing.conformance.checks." .. M.ORDER[n])
end

---Rule that no tool can decide from the repository.
---@param id string
---@param severity string
---@param gate string
---@param title string
---@param reason string
---@return Testing.Conformance.ManualRule
local function manual(id, severity, gate, title, reason)
  return {
    id = id,
    title = title,
    gate = gate,
    severity = severity,
    status = "manual",
    reason = reason,
    source = "testing",
  }
end

local REMOTE = "the state lives on the remote (GitHub), not in a file of the repository"
local JUDGEMENT = "needs a reader's judgement"

---Manual rules, in gate order.
---@type Testing.Conformance.ManualRule[]
M.MANUAL = {
  manual("NEW-01", "critical", "NEW_PROJECT", "Repository created and pushed", REMOTE),
  manual("NEW-02", "recommended", "NEW_PROJECT", "Default branch is main", REMOTE),
  manual("NEW-04", "recommended", "NEW_PROJECT", "GitHub description and homepage", REMOTE),
  manual("NEW-05", "nice-to-have", "NEW_PROJECT", "GitHub topics", REMOTE),
  manual(
    "NEW-09",
    "recommended",
    "NEW_PROJECT",
    "A @types folder per level",
    "what a level is: " .. JUDGEMENT
  ),
  manual(
    "NEW-12",
    "nice-to-have",
    "NEW_PROJECT",
    "Sister-plugin link after the ASCII art",
    JUDGEMENT
  ),
  manual(
    "NEW-16",
    "critical",
    "NEW_PROJECT",
    "lib.nvim as a dependency",
    "which requires are hard dependencies: " .. JUDGEMENT
  ),
  manual(
    "NEW-17",
    "recommended",
    "NEW_PROJECT",
    "lib.nvim modules instead of home-made ones",
    "compare with lib.nvim's docs/modules.md: " .. JUDGEMENT
  ),
  manual("NEW-18", "recommended", "NEW_PROJECT", "Reusable code moved to lib.nvim", JUDGEMENT),
  manual(
    "NEW-19",
    "recommended",
    "NEW_PROJECT",
    "documentation.nvim as a dev dependency",
    JUDGEMENT
  ),
  manual("NEW-20", "recommended", "NEW_PROJECT", "scripts/gen_map.lua per REUSE.md", JUDGEMENT),
  manual(
    "NEW-21",
    "critical",
    "NEW_PROJECT",
    "Keymaps modifiable and switchable off",
    "K3 checks the keymaps of the configured setup; that every lhs is read from the options is code review"
  ),
  manual(
    "NEW-22",
    "recommended",
    "NEW_PROJECT",
    "which-key support",
    "K4 checks the desc of the registered keymaps; the which-key groups are code review"
  ),
  manual(
    "NEW-23",
    "recommended",
    "NEW_PROJECT",
    "Compound user command with completion",
    "K5 and K12 report candidates; whether one command tree is the right shape is " .. JUDGEMENT
  ),
  manual("NEW-24", "recommended", "NEW_PROJECT", "Features on by default", JUDGEMENT),
  manual(
    "NEW-25",
    "recommended",
    "NEW_PROJECT",
    "Count support decided for every keymap",
    JUDGEMENT
  ),
  manual(
    "NEW-26",
    "critical",
    "NEW_PROJECT",
    "Completion for closed value sets",
    "K5 reports commands without -complete; whether a value set is closed is " .. JUDGEMENT
  ),
  manual(
    "NEW-28",
    "recommended",
    "NEW_PROJECT",
    "Every configuration key has a type",
    "LUA-82 (K15) looks for validation and @field; a typed key per key is code review"
  ),
  manual("NEW-29", "nice-to-have", "NEW_PROJECT", "Missing useful options", JUDGEMENT),
  manual(
    "NEW-30",
    "critical",
    "NEW_PROJECT",
    "Cross-platform from the start",
    "run the plugin on Windows and POSIX (REL-19); the CI matrix is the nearest evidence"
  ),
  manual(
    "NEW-31",
    "recommended",
    "NEW_PROJECT",
    "An alternative where cross-platform is not possible",
    JUDGEMENT
  ),
  manual(
    "NEW-32",
    "nice-to-have",
    "NEW_PROJECT",
    "Obvious useful features done at once",
    JUDGEMENT
  ),
  manual(
    "NEW-33",
    "recommended",
    "NEW_PROJECT",
    "Bigger ideas in the vault's roadmap",
    "lives in the vault, not in the repository"
  ),
  manual(
    "NEW-34",
    "critical",
    "NEW_PROJECT",
    "Everything committed and pushed",
    "the suite starts no process and reads no git state (REL-29 is a check in rules.nvim)"
  ),
  manual(
    "NEW-35",
    "critical",
    "NEW_PROJECT",
    "docs/BINDINGS.md maintained in the plugin",
    "K14 compares the registry with the text; that the document explains every binding is "
      .. JUDGEMENT
  ),
  manual(
    "NEW-40",
    "critical",
    "NEW_PROJECT",
    "The runner fails loudly",
    "read scripts/test.sh and minimal_init.lua: " .. JUDGEMENT
  ),
  manual(
    "NEW-41",
    "recommended",
    "NEW_PROJECT",
    "need-check-nil suppressed in the file header with a reason",
    JUDGEMENT
  ),
  manual(
    "NEW-42",
    "recommended",
    "NEW_PROJECT",
    "Test doubles over vim.* suppressed with a reason",
    JUDGEMENT
  ),
  manual(
    "NEW-43",
    "critical",
    "NEW_PROJECT",
    "No test case that skips itself",
    "testing.nvim reports every skip and --strict makes it red; a case wrapped in an if is "
      .. JUDGEMENT
  ),
  manual(
    "NEW-44",
    "recommended",
    "NEW_PROJECT",
    "lua-language-server --check at zero",
    "the suite starts no external tool; run luals-scan (LLS-06) in CI"
  ),
  manual("NEW-46", "nice-to-have", "NEW_PROJECT", "LuaLS diagnostics chapter read", JUDGEMENT),
  manual(
    "NEW-52",
    "recommended",
    "NEW_PROJECT",
    "No AI co-author in commits",
    "needs git history; the suite starts no process"
  ),
  manual(
    "NEW-53",
    "nice-to-have",
    "NEW_PROJECT",
    "Literature and references for plans and studies",
    JUDGEMENT
  ),
  manual(
    "REL-02",
    "recommended",
    "RELEASE",
    "ASCII art and badges at the top of the README",
    JUDGEMENT
  ),
  manual(
    "REL-03",
    "recommended",
    "RELEASE",
    "README table of contents (level-2 headings only)",
    JUDGEMENT
  ),
  manual(
    "REL-04",
    "recommended",
    "RELEASE",
    "Sister-plugin paragraph after the ASCII art",
    JUDGEMENT
  ),
  manual("REL-08", "critical", "RELEASE", "Every README example runs", "run them"),
  manual("REL-09", "nice-to-have", "RELEASE", "Demo video or GIF", JUDGEMENT),
  manual(
    "REL-12",
    "critical",
    "RELEASE",
    "setup() without options is useful",
    "K2 calls setup() with the configured options; whether the bare call is useful is " .. JUDGEMENT
  ),
  manual(
    "REL-14",
    "critical",
    "RELEASE",
    "Dependencies declared correctly and completely",
    "K1 and K7 report requires that fail or are soft; the README block is " .. JUDGEMENT
  ),
  manual(
    "REL-15",
    "recommended",
    "RELEASE",
    "Plugin and modules are lazy",
    "K1 reports top-level side effects; whether a module may load later is " .. JUDGEMENT
  ),
  manual("REL-18", "nice-to-have", "RELEASE", "Test results flow into :checkhealth", JUDGEMENT),
  manual(
    "REL-19",
    "critical",
    "RELEASE",
    "Tried on Windows and on POSIX",
    "a green CI run on both is evidence, not proof"
  ),
  manual("REL-20", "critical", "RELEASE", "Keymaps modifiable and switchable off", "see NEW-21"),
  manual("REL-21", "recommended", "RELEASE", "which-key support", "see NEW-22"),
  manual("REL-22", "recommended", "RELEASE", "Compound user command with completion", "see NEW-23"),
  manual("REL-23", "recommended", "RELEASE", "Features on by default", JUDGEMENT),
  manual("REL-24", "recommended", "RELEASE", "Every configuration key has a type", "see NEW-28"),
  manual("REL-25", "critical", "RELEASE", "GitHub description and homepage", REMOTE),
  manual("REL-26", "recommended", "RELEASE", "GitHub topics", REMOTE),
  manual("REL-27", "recommended", "RELEASE", "Default branch is main", REMOTE),
  manual(
    "REL-29",
    "critical",
    "RELEASE",
    "Everything committed and pushed",
    "the suite starts no process; rules.nvim has a check for it"
  ),
  manual("REL-31", "recommended", "RELEASE", "Reusable functions moved to lib.nvim", JUDGEMENT),
  manual("REL-32", "nice-to-have", "RELEASE", "Literature and references section", JUDGEMENT),
  manual("REL-33", "nice-to-have", "RELEASE", "Logo and social preview", REMOTE),
  manual(
    "REVIEW-1",
    "critical",
    "REVIEW",
    "§1 error handling: pcall at boundaries, guards, structured errors, config merge order (ERR-*)",
    JUDGEMENT
  ),
  manual(
    "REVIEW-2",
    "critical",
    "REVIEW",
    "§2 modularity: single responsibility, coupling, DI (PRIN-*)",
    JUDGEMENT
  ),
  manual(
    "REVIEW-3",
    "critical",
    "REVIEW",
    "§3 buffer and window handles validated, also in callbacks (LUA-10/11, ERR-33)",
    JUDGEMENT
  ),
  manual("REVIEW-4", "recommended", "REVIEW", "§4 state management (LUA-30..33)", JUDGEMENT),
  manual(
    "REVIEW-5",
    "recommended",
    "REVIEW",
    "§5 annotations and comment hygiene (LUA-60..66, CMT-*)",
    JUDGEMENT
  ),
  manual("REVIEW-6", "recommended", "REVIEW", "§6 testability (PRIN-31..34)", JUDGEMENT),
  manual(
    "REVIEW-7",
    "critical",
    "REVIEW",
    "§7 cross-platform beyond XP-01 and XP-06 (PRINCIPLES §8, XP-02..05)",
    JUDGEMENT
  ),
  manual(
    "REVIEW-8",
    "recommended",
    "REVIEW",
    "§8 tools run: lua-language-server --check, stylua --check, luacheck",
    "the suite starts no external tool; they belong to CI"
  ),
  manual(
    "REVIEW-9",
    "critical",
    "REVIEW",
    "§9 security beyond SEC-22 and SEC-47 (SEC-01..51)",
    JUDGEMENT
  ),
}

return M
