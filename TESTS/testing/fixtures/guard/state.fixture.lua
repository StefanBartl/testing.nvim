---@diagnostic disable: duplicate-set-field
-- Scenarios of the state-leak guard (RED: the case leaves something behind, GREEN: it does not).
-- Run by TESTS/testing/guard_state_spec.lua in a real child editor.

local B = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/boot.lua")

---Only the state guard.
---@param extra? table state guard options
---@return table
local function only_state(extra)
  ---@type table<string, any>
  local g = { state = vim.tbl_extend("force", { mode = "error" }, extra or {}) }
  for _, name in ipairs({ "fs", "scheduled_error", "prompt", "deprecation", "process_net", "clock" }) do
    g[name] = "off"
  end
  return { guards = g }
end

B.case("red_autocmd", {
  cfg = only_state(),
  body = function()
    local grp = vim.api.nvim_create_augroup("LeakGrp", { clear = true })
    vim.api.nvim_create_autocmd("BufEnter", { group = grp, pattern = "*.lua", command = "echo 1" })
  end,
})

B.case("red_autocmd_no_group", {
  cfg = only_state(),
  body = function()
    vim.api.nvim_create_autocmd("InsertLeave", { callback = function() end })
  end,
})

B.case("red_usercmd", {
  cfg = only_state(),
  body = function()
    vim.api.nvim_create_user_command("LeakedCmd", "echo 1", {})
  end,
})

B.case("red_keymap", {
  cfg = only_state(),
  body = function()
    vim.api.nvim_set_keymap("n", "<leader>zq", ":echo 1<CR>", {})
  end,
})

B.case("red_keymap_replaced", {
  cfg = only_state(),
  setup = function()
    vim.api.nvim_set_keymap("n", "<leader>zr", ":echo 1<CR>", {})
  end,
  body = function()
    vim.api.nvim_set_keymap("n", "<leader>zr", ":echo 2<CR>", {})
  end,
})

B.case("red_keymap_buffer_local", {
  cfg = only_state(),
  setup = function()
    return vim.api.nvim_create_buf(true, false)
  end,
  body = function(_, buf)
    vim.api.nvim_buf_set_keymap(buf, "n", "zz", ":echo 1<CR>", {})
  end,
})

B.case("red_buffer", {
  cfg = only_state(),
  body = function()
    local b = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(b, "leaked-buffer.txt")
  end,
})

B.case("red_window_tab", {
  cfg = only_state(),
  body = function()
    vim.cmd("split")
    vim.cmd("tabnew")
  end,
})

B.case("red_cwd", {
  cfg = vim.tbl_extend(
    "force",
    only_state(),
    { roots = { tmp = vim.fs.dirname(B.sandbox().outside) } }
  ),
  setup = function()
    return { start = vim.uv.cwd(), dir = B.sandbox().outside }
  end,
  body = function(_, env)
    vim.api.nvim_set_current_dir(env.dir)
  end,
  after = function(_, _, env)
    vim.api.nvim_set_current_dir(assert(env.start))
  end,
})

B.case("red_option", {
  cfg = only_state(),
  body = function()
    vim.o.scrolloff = 7
  end,
})

B.case("red_var_env_global", {
  cfg = only_state(),
  body = function()
    vim.g.leaked_flag = 1
    vim.env.LEAKED_TESTING_VAR = "secret-value"
    _G.leaked_global = true
  end,
})

B.case("red_highlight", {
  cfg = only_state(),
  body = function()
    vim.api.nvim_set_hl(0, "LeakedHl", { fg = "#ff0000" })
  end,
})

B.case("red_rtp", {
  cfg = only_state(),
  body = function()
    vim.opt.rtp:append(B.sandbox().outside)
  end,
})

B.case("red_channel", {
  cfg = only_state(),
  body = function()
    local exe = vim.v.progpath
    vim.fn.jobstart({ exe, "--headless", "-n", "-i", "NONE", "-u", "NONE", "-c", "sleep 30" })
  end,
  after = function()
    for _, c in ipairs(vim.api.nvim_list_chans()) do
      if c.stream == "job" then
        pcall(vim.fn.jobstop, c.id)
      end
    end
  end,
})

B.case("info_module", {
  cfg = only_state(),
  body = function()
    package.loaded["leaky.module.x"] = { 1 }
  end,
})

B.case("green_nothing", {
  cfg = only_state(),
  body = function() end,
})

B.case("green_cleaned_up", {
  cfg = only_state(),
  body = function()
    local grp = vim.api.nvim_create_augroup("CleanGrp", { clear = true })
    vim.api.nvim_create_autocmd("BufEnter", { group = grp, command = "echo 1" })
    vim.api.nvim_del_augroup_by_id(grp)
    vim.api.nvim_create_user_command("CleanCmd", "echo 1", {})
    vim.api.nvim_del_user_command("CleanCmd")
    vim.api.nvim_set_keymap("n", "<leader>zc", ":echo 1<CR>", {})
    vim.api.nvim_del_keymap("n", "<leader>zc")
    local b = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_delete(b, { force = true })
    local old = vim.o.scrolloff
    vim.o.scrolloff = 9
    vim.o.scrolloff = old
    vim.g.clean_flag = 1
    vim.g.clean_flag = nil
    vim.cmd("split")
    vim.cmd("close")
  end,
})

B.case("green_ignored_group", {
  cfg = only_state({ ignore_groups = { "testing.guard", "HarnessGrp" } }),
  body = function()
    local grp = vim.api.nvim_create_augroup("HarnessGrp", { clear = true })
    vim.api.nvim_create_autocmd("BufEnter", { group = grp, command = "echo 1" })
  end,
})

B.case("green_category_off", {
  cfg = only_state({ categories = { autocmds = "off", options = "off" } }),
  body = function()
    vim.api.nvim_create_autocmd("BufEnter", { command = "echo 1" })
    vim.o.scrolloff = 5
  end,
})

B.case("warn_strict", {
  cfg = vim.tbl_extend("force", only_state(), { strict = true }),
  body = function()
    vim.o.scrolloff = 6
  end,
})

B.case("restore", {
  cfg = only_state(),
  restore = true,
  setup = function()
    local sb = B.sandbox()
    return {
      start = vim.uv.cwd(),
      dir = sb.outside,
      old_so = vim.o.scrolloff,
      bufs = #vim.api.nvim_list_bufs(),
      wins = #vim.api.nvim_list_wins(),
      tabs = #vim.api.nvim_list_tabpages(),
    }
  end,
  body = function(_, env)
    local grp = vim.api.nvim_create_augroup("RestoreGrp", { clear = true })
    vim.api.nvim_create_autocmd("BufEnter", { group = grp, command = "echo 1" })
    vim.api.nvim_create_user_command("RestoreCmd", "echo 1", {})
    vim.api.nvim_set_keymap("n", "<leader>zx", ":echo 1<CR>", {})
    vim.api.nvim_create_buf(true, false)
    vim.cmd("split")
    vim.cmd("tabnew")
    vim.api.nvim_set_current_dir(env.dir)
    vim.o.scrolloff = env.old_so + 3
    vim.g.restore_flag = 1
    vim.env.RESTORE_VAR = "x"
    vim.api.nvim_set_hl(0, "RestoreHl", { fg = "#00ff00" })
  end,
  after = function(_, res, env)
    local autocmds = vim.api.nvim_get_autocmds({ group = "RestoreGrp" })
    local maps = vim.tbl_filter(function(m)
      return m.lhs:find("zx", 1, true)
    end, vim.api.nvim_get_keymap("n"))
    return {
      restored = res.restored,
      autocmds = #autocmds,
      usercmd = vim.fn.exists(":RestoreCmd"),
      maps = #maps,
      bufs = #vim.api.nvim_list_bufs() - env.bufs,
      wins = #vim.api.nvim_list_wins() - env.wins,
      tabs = #vim.api.nvim_list_tabpages() - env.tabs,
      cwd_ok = vim.fs.normalize(assert(vim.uv.cwd())) == vim.fs.normalize(env.start),
      scrolloff_ok = vim.o.scrolloff == env.old_so,
      g = vim.g.restore_flag,
      env = vim.env.RESTORE_VAR,
    }
  end,
})

-- ---------------------------------------------------------------------------------------------
-- What the editor's own runtime changes when a spec loads a filetype or a syntax is NOT a leak of
-- the spec: GREEN. The control with the same shape but a plugin's own name is RED.
B.case("green_runtime_noise", {
  cfg = only_state({
    categories = { vars = "error", options = "error", highlights = "error", lua_globals = "error" },
  }),
  body = function()
    vim.g.markdown_minlines = 50
    vim.g.lua_version = 5
    vim.g.lua_subversion = 1
    vim.g.java_highlight_all = 1
    vim.g.did_load_filetypes = 1
    vim.go.syntax = "lua"
    rawset(_G, "re", {})
    vim.api.nvim_set_hl(0, "CssNoiseGroup", { link = "Type", default = true })
  end,
  after = function()
    rawset(_G, "re", nil)
    vim.go.syntax = ""
  end,
})

B.case("red_noise_lookalikes", {
  cfg = only_state({ categories = { vars = "error", highlights = "error", lua_globals = "error" } }),
  body = function()
    vim.g.markdownish_plugin_flag = 1
    vim.g.my_plugin_state = 1
    rawset(_G, "reality", {})
    vim.api.nvim_set_hl(0, "MyPluginGroup", { fg = "#ff0000" })
  end,
  after = function()
    rawset(_G, "reality", nil)
  end,
})

-- the clipboard provider's job (started by the runtime on the first register access) is not the spec's
local saved_chans
B.case("green_clipboard_provider_job", {
  cfg = only_state({ categories = { channels = "error" } }),
  body = function()
    local real = vim.api.nvim_list_chans
    vim.api.nvim_list_chans = function()
      local list = real()
      list[#list + 1] =
        { id = 9001, stream = "job", argv = { "C:\\tools\\win32yank.exe", "-i", "--crlf" } }
      return list
    end
    saved_chans = real
  end,
  after = function()
    vim.api.nvim_list_chans = saved_chans
  end,
})

B.case("red_other_job_still_named", {
  cfg = only_state({ categories = { channels = "error" } }),
  body = function()
    local real = vim.api.nvim_list_chans
    vim.api.nvim_list_chans = function()
      local list = real()
      list[#list + 1] =
        { id = 9002, stream = "job", argv = { "C:/tools/dev-server.exe", "--serve" } }
      return list
    end
    saved_chans = real
  end,
  after = function()
    vim.api.nvim_list_chans = saved_chans
  end,
})

B.finish()
