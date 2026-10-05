# For plugin authors: migrating from busted or plenary

The point of testing.nvim is that you do **not** rewrite specs. Your existing files stay as they
are; only the way they are started changes.

What your specs look like decides which dialect runs them ([DIALECTS.md](DIALECTS.md)):

| Your specs | Today | After migrating |
| --- | --- | --- |
| `describe` / `it` with luassert, started by `PlenaryBustedDirectory` or `busted` | needs plenary or busted installed | the `busted` dialect, no plenary |
| `return function(H) ... end` on a `TESTS/harness.lua` | a hand-written `TESTS/run.lua` | dialects `a`, `b`, `c` or `h` |
| `require("harness")` and `M.run()` | a hand-written `TESTS/run.lua` | dialect `d` |

## Steps

1. **Check out testing.nvim and lib.nvim.** The runner is a script you start by path, so
   testing.nvim can live anywhere. lib.nvim must be where the runner can find it: `$LIB_NVIM_DIR`,
   `.deps/lib.nvim`, a sibling directory, or `stdpath("data")/lazy/lib.nvim`
   ([CONFIG.md](CONFIG.md#dependencies)). In CI, check both out into `.deps/`.

2. **Run it as it is.** From the root of your plugin:

   ```sh
   nvim -n -i NONE --headless -u NONE -l <testing.nvim>/scripts/testing.lua .
   ```

   Nothing in your repository changes. Add `--list` first to see which spec file runs in which
   dialect, and why a file is `unknown` if it is.

3. **Read what it tells you.** A run reports problems with where specs live (legacy `tests/`
   directories, busted specs under `lua/`), with files whose dialect it cannot decide, and with
   luassert features the busted dialect does not have (`spy`, `stub`, `mock`, `insulate`, ...). Those
   fail loudly with a message that names the feature; that is intended. Everything else behaves the
   way it did, with one difference worth knowing: a failed assertion no longer aborts the test body,
   so you see every failure of a test at once.

4. **Add a `.testing.lua`** only if the defaults do not fit ([CONFIG.md](CONFIG.md)): another spec
   root, a forced dialect, or `deps` for libraries your specs need on the runtimepath (for example
   `deps = { "plenary.nvim" }` while a spec still `require`s plenary modules other than its test
   functions).

5. **Switch your entry points.** Make `scripts/test.sh` (or your `Makefile`, or the CI step) call the
   runner instead of `PlenaryBustedDirectory` / `busted` / `TESTS/run.lua`; `scripts/test.sh` of this
   repository is a template. Use `--json` and `--junit` in CI and upload them as artifacts when the
   job fails ([OUTPUT-FORMATS.md](OUTPUT-FORMATS.md)).

6. **Remove the old runner** once both give the same verdict. If your old runner printed a sentinel
   line that a script reads, keep the name with `--sentinel`.

## What is the same

* File discovery (`*_spec.lua`), `describe` / `it` order of execution, hook order, `pending`.
* The exit code: `0` only when everything passed ([EXIT-CODES.md](EXIT-CODES.md)).
* All spec files share one Neovim process, like in the old runners; a spec that needs isolation
  from the others must still clean up after itself.

## What is different on purpose

* No spec can end the run: `os.exit` inside a spec is an error of that file, and quitting the editor
  is exit code `3`.
* A case that asserts nothing, a file that registers no case, and a file whose dialect is unknown
  are failures, never passes.
* Unsupported busted/luassert features raise instead of silently doing nothing.
* A filtered run (`--file`) never prints the "all green" sentinel.
