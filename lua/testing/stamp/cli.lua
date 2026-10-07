---@module 'testing.stamp.cli'
---@brief The own flags of `testing stamp` and `testing verify`, taken out before the run options are parsed.
---@description
--- Like `testing explain`, these two commands have flags that are not options of a run. `split_argv` removes
--- them (and the command word of `stamp`, which is a run) and hands the rest to the ordinary parser, so a run
--- option (`--config`, `--isolated`, `--env-allow`, ...) means what it means in a run: the cache key depends on it.

local M = {}

---@class Testing.Stamp.CliSpec
---@field flags table<string, string> Boolean flags: flag -> field.
---@field values table<string, string> Flags with a value: flag -> field.

---@type table<string, Testing.Stamp.CliSpec>
M.SPECS = {
  verify = {
    flags = {
      ["--json"] = "json",
      ["--from-note"] = "from_note",
      ["--allow-dirty"] = "allow_dirty",
      ["--require-hmac"] = "require_hmac",
    },
    values = { ["--stamp"] = "stamp", ["--max-age"] = "max_age" },
  },
  stamp = {
    flags = { ["--note"] = "note" },
    values = { ["--out"] = "out" },
  },
}

---Take the flags of `verify` or `stamp` out of the arguments (`argv[1]` is the command word).
---For `verify` the word stays (it is a subcommand of the parser); for `stamp` it goes (the rest is a plain run).
---@param argv string[]
---@return string[] rest
---@return table own
---@return string|nil problem
function M.split_argv(argv)
  local command = argv[1]
  local spec = M.SPECS[command]
  local own = { command = command }
  if not spec then
    return argv, own, nil
  end
  for _, field in pairs(spec.flags) do
    own[field] = false
  end
  local rest = {}
  if command == "verify" then
    rest[1] = "verify"
  end
  local i, n = 2, #argv
  local done = false
  while i <= n do
    local a = argv[i]
    local name, inline = a:match("^(%-%-[^=]+)=(.*)$")
    name = name or a
    if done or a == "--" then
      done = true
      rest[#rest + 1] = a
    elseif spec.flags[name] and inline == nil then
      own[spec.flags[name]] = true
    elseif spec.values[name] then
      local value = inline
      if value == nil then
        value = argv[i + 1]
        i = i + 1
      end
      if value == nil or value == "" or (inline == nil and value:sub(1, 2) == "--") then
        return rest, own, ("option %s needs a value"):format(name)
      end
      if spec.values[name] == "max_age" then
        local secs, why = require("testing.stamp").parse_age(value)
        if not secs then
          return rest, own, ("option --max-age: %s"):format(why)
        end
        value = secs
      end
      own[spec.values[name]] = value
    else
      rest[#rest + 1] = a
    end
    i = i + 1
  end
  return rest, own, nil
end

return M
