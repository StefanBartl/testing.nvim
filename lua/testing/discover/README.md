# `testing.discover`

`discover(root, opts)` finds the specs of a project and reports what is wrong with where they live. It never raises
on what it finds; problems are `findings` (data).

* `init.lua`: `discover`, `runner_hints` (spec list and sentinel of the project's own `TESTS/run.lua`), `find_sentinel`,
  `glob_match` (a non-backtracking glob matcher for dialect overrides), `order` (apply that list; listed-but-missing specs stay as `missing` placeholders).
* `sniff.lua`: dialect by signature sniffing (`a`, `b`, `c`, `d`, `busted`, `script`, else `unknown` with a reason);
  overrides win.
* `harness_profile.lua`: static reading of a project's `harness.lua`: may a fixed shim stand in for it?
* `positions.lua`: `describe`/`it` positions, tree-sitter with a regex fallback (the answer names its backend).
* `lua_text.lua`: comment/string scanner the sniffers use (`code_only`, `strip_comments`, `strings`).

Rules: no depth limit; symlinked directories are reported and not entered (ERR-34); legacy places
(`docs/TESTS`, `tests`, `test`, `scripts`) are listed and reported (NEW-48); busted specs below `lua/` are reported,
not run; an unknown dialect is an error finding; a project without specs is an error finding.

## Which files are specs

`opts.spec_pattern` is a list of Lua patterns matched against the project-relative path (`.testing.lua`:
`spec_pattern`, default `{ "_spec%.lua$" }`). A project whose specs have no suffix (filetree.nvim: `TESTS/units.lua`)
says so, e.g. `{ "^TESTS/[%w_]+%.lua$" }`. `harness.lua`, `run.lua` and `minimal_init.lua` are never specs, whatever the
pattern. The legacy places and the `lua/` scan keep the `_spec.lua` suffix.

## Which dialect a file gets

1. An explicit dialect wins and is never second-guessed. `opts.dialect` (`.testing.lua`: `dialect`) is a name for every
   file or a table `{ [path or glob] = name, ["*"] = name }`. A key is a literal relative path or a glob (`*` within a
   segment, `**` across segments, `?` one character); the most specific key wins: literal path, then the glob with the
   most literal characters, then `*`. Names: `auto`, `testing`, `a`, `b`, `c`, `d`, `h`, `busted`, `script`.
2. Otherwise the file text is sniffed (`sniff.lua`):
   * `describe`/`it` at statement start: `busted`; `require("harness")` plus a `run` function: `d`;
   * `return function(H)`: `a`, `b` or `c` by the helpers it uses and the FORM of the calls (`scratch()`,
     `scratch("lua")`, `scratch({..})`, `tmpdir()`, `tmpdir(function ...)`). A file that uses a key only b or c have is
     never `a`. A key or call form no shim implements (`H.match`, the project's own `scratch(ft, lines)`) makes the file
     `unknown` with `h_style`: a project harness can run it;
   * no framework but a top-level `os.exit(` / `cquit`: `script`, a self-running script (pickers.nvim, cmdlog.nvim,
     filetree.nvim) that the child driver runs in its own process, judged by exit code and output
     (`testing.dialect.script`);
   * nothing matches: `unknown`, an error finding.
3. **The project's own harness wins when a shim cannot be proven equivalent.** For a file sniffed as `a`/`b`/`c` in a
   project that has a `harness.lua` above it, `harness_profile` compares every helper the file uses with the shim's
   reference (parameter names in order; `eq` must be a strict `==`, `ok` a truthiness check) and the file runs on the
   project's harness (dialect `h`, entry field `harness`, `sniffed` = what the sniffer said) unless all of them match.
   A harness that lacks a helper the shim has keeps the shim (the project's runner may inject it). In doubt (an `H`
   that is handed on, an `eq` that cannot be read) it is `h`. The evidence of every file says which; one `project_harness`
   info finding per harness names the first reason.

   Measured on the fleet (1251 spec files of 40 repositories): 20 files change from a shim to `h` (color_my_ascii 11,
   tasks 4, buffer-ctx 2, fileops 2, recommender 1) and 2 files that were `unknown` become `script` (pickers.nvim,
   cmdlog.nvim); every file that failed on a shim in the parity measurement runs green on its own harness.

## The project's runner (`TESTS/run.lua`)

`runner_hints` reads the spec list (both spellings: `"name_spec.lua"` and `"name_spec"`) and the sentinel the project's
own runner prints on success. The sentinel is an upper-case word ending in `_OK` inside a string literal of any quoting
form (`print("\nLIB_TESTS_OK")`, `print('\nCOLOR_MY_ASCII_TESTS_OK')`, `print("EMOJIS_TESTS_OK")` without a newline,
`say(("\nTASKS_TESTS_OK (%d spec(s))"):format(n))`, `io.stdout:write(...)`); a token on a printing line wins over
other tokens, comments are ignored.
