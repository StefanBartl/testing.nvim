---@module 'testing.child.fragment'
---@brief The Result-IR fragment a child writes and the parent merges: newline-delimited JSON.
---@description
--- A child editor runs ONE spec file and reports through a file (never through stdout, which a spec
--- may fill with anything):
---
---   {"k":"progress","case":{...}}                      a case the moment it finished (may still change)
---   {"k":"case","case":{...Testing.Result.Case...}}     the FINAL cases, written when the file is over
---   {"k":"done","files_run":1,"files_unselected":0}      last line, written when the file is over
---
--- Streaming (`progress` lines, one per case, not one document at the end) is what keeps the results of
--- a file whose child is killed by the hard timeout: the cases that finished before the kill are not
--- lost. A file that finishes uses its `case` records and ignores the `progress` ones (the driver
--- may still adjust a case after the dialect finished it, e.g. when the file deadline passed); a file
--- that does not finish has only `progress` records, and those are used. The
--- parent reads the file after the child is gone; a half-written last line (the child died in the
--- middle of a write) is dropped and counted, never guessed.
---
--- The parent does not trust the fragment: `check` runs the IR validator over it (shape, status
--- enum, unique ids, verdict consistent with the assertions) and refuses cases that name a file other
--- than the one the child was asked to run. Path placeholders and redaction are NOT applied here: the
--- merged IR goes through the very same `sanitize` as an in-process run, once, at the end.

local result = require("testing.core.result")

local M = {}

---Largest fragment the parent reads (bytes); a bigger file is a misbehaving child.
M.MAX_BYTES = 64 * 1024 * 1024

---Append one record (child side). Opens, writes, flushes and closes per record: a kill between two
---records leaves a valid file.
---@param path string
---@param record table
---@return boolean ok
---@return string|nil err
function M.append(path, record)
  local line, err = result.encode(record)
  if not line then
    return false, err
  end
  local f, oerr = io.open(path, "ab")
  if not f then
    return false, tostring(oerr)
  end
  f:write(line, "\n")
  f:flush()
  f:close()
  return true, nil
end

---@class Testing.Child.Fragment
---@field cases Testing.Result.Case[] The final cases, in file order.
---@field progress Testing.Result.Case[] The cases streamed while the file ran, in file order.
---@field done? table The `done` record, nil when the child never got that far.
---@field bad_lines integer Lines that were not valid JSON records (a torn last line counts).
---@field missing boolean The file does not exist.

---Read a fragment (parent side).
---@param path string
---@return Testing.Child.Fragment
function M.read(path)
  ---@type Testing.Child.Fragment
  local frag = { cases = {}, progress = {}, bad_lines = 0, missing = false }
  local stat = vim.uv.fs_stat(path)
  if not stat then
    frag.missing = true
    return frag
  end
  if stat.size > M.MAX_BYTES then
    frag.bad_lines = 1
    return frag
  end
  local f = io.open(path, "rb")
  if not f then
    frag.missing = true
    return frag
  end
  local text = f:read("*a") or ""
  f:close()
  local json = require("lib.nvim.json")
  for line in text:gmatch("[^\n]+") do
    local rec = json.decode(line)
    if type(rec) ~= "table" then
      frag.bad_lines = frag.bad_lines + 1
    elseif rec.k == "case" and type(rec.case) == "table" then
      frag.cases[#frag.cases + 1] = rec.case
    elseif rec.k == "progress" and type(rec.case) == "table" then
      frag.progress[#frag.progress + 1] = rec.case
    elseif rec.k == "done" then
      frag.done = rec
    else
      frag.bad_lines = frag.bad_lines + 1
    end
  end
  return frag
end

---Validate the cases of a fragment: the IR rules plus "only this file".
---@param cases Testing.Result.Case[]
---@param rel string The spec the child was asked to run.
---@return boolean ok
---@return string[] problems
function M.check(cases, rel)
  local problems = {}
  for i, c in ipairs(cases) do
    if type(c.file) == "string" and c.file ~= rel then
      problems[#problems + 1] = ("cases[%d].file: %q, the child was asked to run %q"):format(
        i,
        c.file,
        rel
      )
    end
  end
  local ir = {
    schema_version = result.SCHEMA_VERSION,
    run = result.new_run({}),
    cases = cases,
    summary = result.summarize(cases),
  }
  local _, vproblems = result.validate(ir, { allow_abs_paths = true, allow_emails = true })
  vim.list_extend(problems, vproblems)
  return #problems == 0, problems
end

return M
