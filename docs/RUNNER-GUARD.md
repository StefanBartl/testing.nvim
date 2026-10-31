# Protecting a local runner from foreign code

A self-hosted GitHub Actions runner executes a job with the rights of the user it runs as. For a **public**
repository foreign code can get there in two ways:

1. **A pull request that changes the workflow.** The PR sets `runs-on: [self-hosted, windows]` in
   `.github/workflows/ci.yml`; after "Approve and run" its code runs on your machine.
2. **A merge and the push run after it.** Every push to the default branch runs on the runner with everything in the
   repository: specs, `.testing.lua`, `scripts/*.sh`, lock files. Malicious code in a test or script runs here, the
   first time, after the merge.

A check in the workflow or in `scripts/ci.sh` is no barrier: the pull request changes it. So the check lives on the
machine of the runner, outside every work folder. It is the same act as running the tests locally: the review before
the merge is the protection, and `testing ci trust` is where you say you did it.

## What is checked

The runner calls `ACTIONS_RUNNER_HOOK_JOB_STARTED` before every job; a non-zero exit cancels the job. The hook script
only calls `testing ci runner-guard check`, which decides from the `GITHUB_*` variables, in this order:

| # | Rule | Result |
| --- | --- | --- |
| 1 | mode of the repository is `off` | run |
| 2 | event `pull_request` or `pull_request_target` | **refuse** (the code of a pull request never runs here) |
| 2b | any event other than `push`, `workflow_dispatch`, `workflow_run`, `schedule`, `release` (an allowlist: `pull_request_review` and the like run the merge ref of a pull request) | **refuse** |
| 3 | actor, or the actor who triggered a re-run, is not the owner of the repository (the maintainer) | **refuse** |
| 4 | the repository is private and the mode is not `always` | run |
| 5 | the commit (`GITHUB_SHA`) is on the list of reviewed commits | run, else **refuse** |

Anything that cannot be decided refuses: no `GITHUB_*` variables, no `gh` (the repository then counts as public), a
hook script whose `nvim` or `testing.lua` is missing. A list file that is not ours (another version, garbage, too
large) is an empty list: nothing is trusted from it, never an error that lets a job through.

Review is **per commit id, never per author**: the author of a commit is free text and proves nothing. A reviewed id
covers the tree that runs; its ancestors are not executed.

Rule 5 only applies to public repositories (rule 4), so the private repositories are unaffected and keep their
no-friction CI; use `--mode=always` to guard one anyway.

## Setting up

```sh
testing ci runner-guard install      # hook script in <runners>/_guard, one line in each runner's .env
testing ci runner-guard status       # per runner: guarded | not guarded | foreign hook; the list
```

`<runners>` is `$TESTING_RUNNER_ROOT`, else `~/actions-runners` (`--runners=<dir>` overrides both). `install` writes
`<runners>/_guard/job-started.ps1` (it names your `nvim` and this checkout's `scripts/testing.lua` by absolute path)
and sets exactly one line `ACTIONS_RUNNER_HOOK_JOB_STARTED=...` in the `.env` of every runner folder (a folder with a
`run.cmd`). Other lines stay; a hook of someone else is never replaced (reported, exit 1). It is idempotent, and a
runner update keeps `.env`. **A running runner reads `.env` only at its start**: stop and start it.

The runner scripts of the nvim config do this for you: `runners.ps1 start|ensure` runs `install` before it starts a
runner (`-NoGuard` leaves it out).

## Releasing a commit

A refused push run says so in its log ("Set up job") and names the command:

```sh
testing ci trust WKDSteve/tasks.nvim --show        # what changed since the last reviewed commit; records nothing
testing ci trust WKDSteve/tasks.nvim               # release the head of the default branch
testing ci trust WKDSteve/tasks.nvim <sha>         # release a given commit (7 to 40 hex digits, resolved at GitHub)
gh run rerun <id> -R WKDSteve/tasks.nvim           # the refused job, again
```

Without a repository the `origin` of the current folder is used. The review aid lists the commits since the last
reviewed one, their authors, and the files that deserve a close look: `.github/`, `scripts/`, `*.sh`, `*.ps1`,
`*.cmd`, `.testing.lua`, `TESTS/`, `package.json` and lock files, `Cargo.toml`, `build.rs`, `.deps/`. It is
**assistance for you, not a verdict**: a person releases the commit. (A machine reading of the diff can be fooled by
obfuscated code or by instructions written into it.)

Other commands: `testing ci trust --list`; `--revoke [<repo>] [<sha>]` (one commit, or all of the repository);
`--mode=auto|always|off <repo>`; `--note=<text>`. The list is `<runners>/reviewed.json`, at most 50 commits per
repository.

## Going back

```sh
testing ci runner-guard remove       # takes our line out of each .env and deletes the hook script
```

Then stop and start the runners. The list stays (`testing ci trust --revoke <repo>` empties one repository, deleting
`reviewed.json` all). A single repository can be taken out with `--mode=off`.

## Limits

- It stops foreign code that you did not release. It does not stop code you released after a careless review, and not
  someone who can already write to your runner folder or your user account.
- A push of your own to a public repository needs a `trust` call before its run goes through, until an automatic
  release of your own pushes exists (tracked as a follow-up).
- Running jobs in a sandbox (own Windows account, Windows Sandbox, container) would limit the damage of a
  missed review too; it is not part of this guard.
- `testing.nvim`'s own workspace trust (`docs/CLI.md`, `testing trust`) does not help here: `CI=true` makes every
  root trusted in a CI job, which is what a throwaway machine needs and a personal runner is not.
