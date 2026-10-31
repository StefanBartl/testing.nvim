-- TESTS/testing/conformance_k1_progress_spec.lua -- K1 with modules that END the editor when required: the
-- child's progress log names the killer and keeps the results before it, so the run costs one more editor per
-- killer (not a halving of the batch per killer); without the log the halving still finds them.

---@diagnostic disable: need-check-nil -- the case body is the guard: a nil raises and fails the case
return function(H)
  local ok = H.ok
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/conformance/support.lua")
  local conformance = require("testing.conformance")
  local runtime = require("testing.conformance.runtime")

  ---Run K1 alone and count the child editors it started.
  ---@param root string
  ---@param no_log? boolean drop the progress path, as a child that cannot write it would
  ---@return table report
  ---@return integer sessions
  local function k1(root, no_log)
    local real = runtime.session
    local sessions = 0
    runtime.session = function(ctx, name, fn)
      if name == "require" then
        sessions = sessions + 1
      end
      if not no_log then
        return real(ctx, name, fn)
      end
      return real(ctx, name, function(child, P)
        return fn(child, function(fn_name, batch)
          return P(fn_name, batch)
        end)
      end)
    end
    local okr, report = pcall(conformance.run, root, { only = { "K1" } })
    runtime.session = real
    assert(okr, report)
    return report, sessions
  end

  ---@param report table
  ---@return string[] modules K1 reports as ending the editor
  local function killed(report)
    local out = {}
    for _, f in ipairs(S.check(report, "K1").findings) do
      if f.message:find("the editor ended while it was required", 1, true) then
        out[#out + 1] = f.message:match('require%("([^"]+)"%)')
      end
    end
    table.sort(out)
    return out
  end

  S.run(function()
    local repo = S.new_repo()
    S.write(repo .. "/lua/goodp/killer_a.lua", "os.exit(3)\nreturn {}\n")
    S.write(repo .. "/lua/goodp/killer_b.lua", "vim.cmd('qall!')\nreturn {}\n")

    local report, sessions = k1(repo)
    local want = { "goodp.killer_a", "goodp.killer_b" }
    ok(
      vim.deep_equal(killed(report), want),
      "both killers are named: " .. vim.inspect(killed(report)) .. " / " .. S.messages(report, "K1")
    )
    ok(
      S.check(report, "K1").notes[1]:find("8 of 10 module", 1, true) ~= nil,
      "every module has a result, the ones before and after a killer too: "
        .. S.messages(report, "K1")
    )
    ok(sessions == 3, ("one editor, then one more per killer: 3 (got %d)"):format(sessions))

    -- without the log the batch is split until each killer is alone: same result, more editors
    local plain, split = k1(repo, true)
    ok(
      vim.deep_equal(killed(plain), want),
      "the halving names the same killers: " .. vim.inspect(killed(plain))
    )
    ok(
      S.check(plain, "K1").notes[1]:find("8 of 10 module", 1, true) ~= nil,
      "the halving keeps every module: " .. S.messages(plain, "K1")
    )
    ok(
      split > sessions,
      ("the halving needs more editors (%d, with the log %d)"):format(split, sessions)
    )
  end)
end
