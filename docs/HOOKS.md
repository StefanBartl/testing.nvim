# Hook recipes

Git hooks and a Claude Code `Stop` hook that put the verdict of testing.nvim in front of a push, a commit or the end of
an agent's turn. `:Testing init --hooks` writes them (below); installing them is a command of yours.

The one rule: **a hook computes no verdict**. Its exit code and its text are those of `testing`; a spec
(`hooks_spec`) checks that the scripts contain no `grep`, no sentinel name, no `green` in their code, and that every
call goes through one function. The other thing hooks get wrong is looking at something other than what is committed or
pushed: a run sees the **working tree**, not the index. Each recipe says what it does about that.

## Install

```sh
:Testing init --hooks          # in the editor; writes scripts/hooks/{_testing.sh,pre-push,pre-commit,claude-stop}
git config core.hooksPath scripts/hooks
```

`:Testing init --hooks` never replaces a file that exists (`--force` does not apply to it) and runs again without
harm. Nothing is written to `.git/hooks`, `.claude/settings.json` or any configuration: the `core.hooksPath` setting and
the Claude Code registration are yours. The scripts find the runner like `scripts/test.sh` does (`$TESTING_NVIM_DIR`,
`.deps/testing.nvim`, `../testing.nvim`, `stdpath('data')/lazy/testing.nvim`) and say so, exit 1, when they do not.
Tested with Git Bash on Windows and with bash on Linux and macOS (the spec runs the hooks where `bash` exists).

## pre-push

```sh
testing verify . --stamp "$GIT_DIR/testing/stamp.json" && exit 0
testing stamp . --cached --order priority --reporter agent --out "$GIT_DIR/testing/stamp.json"
```

1. It refuses a push whose pushed object is not `HEAD` (the run would test `HEAD`, not what is pushed; a deletion is
   skipped) and a **dirty tree** (`git status --porcelain` is not empty: what would be tested is not what is pushed),
   with a message that says what to do. This is the answer to "does the hook check what is pushed": it checks `HEAD` of a
   clean tree, or it refuses.
2. `testing verify` answers from the cache keys without running a spec ([CACHE.md](CACHE.md#stamp)). `verified` ends the
   hook with exit 0.
3. Anything else (`partial`, `changed`, `expired`, ...) runs the suite as `testing stamp`: a run on the cache with
   the failed and changed specs first and the compact `agent` reporter, which writes the stamp for the next push after a
   complete green run. A red run blocks the push with testing's exit code.

The stamp lives in the git directory (`.git/testing/stamp.json`): not in the tree (the tree stays clean) and not in a
throwaway state directory. A suite with files that have no key (clock, process, ...) can never be `verified`: every push
runs those files; the cache still makes the rest cheap.

`testing fast` (the planned two-phase fast loop) does not exist yet; the recipe uses what it will be made of
(`--cached --order priority --reporter agent`). When `testing fast` lands, replace the second command.

## pre-commit

```sh
testing run . --changed --cached --order priority --reporter agent
```

Only the fast path, and an honest one: the specs the working tree can reach, from the cache where keys allow. That is a
**partial run**: exit 0 means "nothing failed among those", there is no sentinel, and when nothing is affected testing
says so ("nothing ran. This is not a green run").

Known limit: the run checks the **working tree**. With changes that are only partly staged it checks something other
than what is committed; the hook says so on stderr (`some changes are not staged`). Checking the index itself
(`git checkout-index --prefix=<tmp>/` into a temporary directory, then a run there) is not part of the recipe: the keys do
not depend on the path (`ci_cache_spec`), but the dependencies of the project (`lib.nvim`, ...) are found next to the
checkout or in `.deps`, which a temporary directory does not have, so a generic script cannot do it. A project that
can resolve its dependencies from environment variables alone can build it on top of `_testing.sh`; `git stash
--keep-index` is not recommended (an interrupted hook leaves the stash behind).

## Claude Code `Stop` hook

Register it in `.claude/settings.json` (or the user settings) yourself:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "bash scripts/hooks/claude-stop" } ] }
    ]
  }
}
```

`scripts/hooks/claude-stop` runs `testing run . --cached --order priority --reporter agent`. When that exits non-zero it
prints testing's own text to stderr and exits 2; otherwise it exits 0 and says nothing.

### Pruefpunkte: what is documented and what is not

Checked against the Claude Code hooks documentation (`code.claude.com/docs/en/hooks`, fetched **2026-10-07**; re-check
before relying on any of it, the behaviour belongs to Claude Code, not to testing.nvim):

| Statement | Status |
| --- | --- |
| The `Stop` event fires when Claude finishes responding, before the turn ends | documented |
| Exit code 2 of a `Stop` hook blocks the stop; stderr is shown to Claude as the reason | documented |
| The input on stdin is JSON with `hook_event_name`, `session_id`, `transcript_path`, `cwd`, `last_assistant_message`, `stop_hook_active` and more | documented (field list); the set of fields can change |
| Registration is `hooks` -> `Stop` -> a list of `{ "hooks": [ { "type": "command", "command": ... } ] }`; `Stop` has no matcher | documented |
| Default timeout of a command hook is 600 seconds | documented |
| **What `stop_hook_active` means** (that a Stop hook already blocked in this turn) and that it stops a loop | **not documented in what was fetched: an assumption** |
| Whether exit 2 on every turn can loop for ever without the guard | **not established** |
| Whether a hook that exits 2 interacts with a `PostToolUse` or other hook | **not examined** |
| Alternative `{"decision":"block","reason":...}` on exit 0 | documented, not used |

The script's loop guard (`stop_hook_active` true: let the stop through) rests on the first undocumented row. If the
meaning is different the guard is wrong in one of two directions: a red suite can stop the agent anyway, or a red suite
can keep it from ever stopping. Check it in your Claude Code version with a deliberately red suite before you depend on
it. A `PostToolUse` hook on file edits would be far too noisy and is not provided.

## What the hooks do not do

- They never print or compute "green". `verified` and the sentinel come from `testing verify` / `testing run` only.
- They are not a gate that cannot be skipped: `git push --no-verify` and a disabled hook bypass them. Server-side CI is
  the gate ([CI-CACHE.md](CI-CACHE.md)).
- They do not install themselves, configure Claude Code, or touch `.git/hooks`.
