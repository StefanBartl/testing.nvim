# `testing.discover`

`discover(root, opts)` finds the specs of a project and reports what is wrong with where they live. It never raises
on what it finds; problems are `findings` (data).

* `init.lua`: `discover`, `runner_hints` (spec list and sentinel of the project's own `TESTS/run.lua`), `order`
  (apply that list; listed-but-missing specs stay as `missing` placeholders).
* `sniff.lua`: dialect by signature sniffing (`a`, `b`, `c`, `d`, `busted`, else `unknown` with a reason); overrides win.
* `positions.lua`: `describe`/`it` positions, tree-sitter with a regex fallback (the answer names its backend).
* `lua_text.lua`: comment/string scanner both sniffers use.

Rules: no depth limit; symlinked directories are reported and not entered (ERR-34); legacy places
(`docs/TESTS`, `tests`, `test`, `scripts`) are listed and reported (NEW-48); busted specs below `lua/` are reported,
not run; an unknown dialect is an error finding; a project without specs is an error finding.
