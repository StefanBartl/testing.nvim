# `testing.dialect`

Shims that let existing spec files run on the kernel (`testing.core`) without being edited.

| Module | Purpose |
|--------|---------|
| [`testing.dialect.harness_a`](harness_a.lua) | Dialect A: `return function(H) ... end`, the `H` of lib.nvim's `TESTS/harness.lua` |

## Dialect A

```lua
-- a spec file, exactly as before
return function(H)
  H.eq(1, 2, "first")   -- recorded, the file keeps running
  H.ok(false, "second") -- recorded too: both failures are reported
end
```

`harness_a.new(ctx)` builds `H` on one `testing.core.assert` context:

* `H.eq` (strict `==`) and `H.ok` (truthy) are the collecting `eq` / `ok`; arguments are
  `(actual, expected, msg)` / `(value, msg)` like before. They do not raise, so every failed check of a
  file is visible; the call site (`file:line`) of the spec is recorded.
* `H.tmpfile(suffix?)`, `H.read_lines(path)`, `H.with_patched(target, key, value, fn)` and
  `H.with_stdpath_config(link, fn)` behave like the originals (`with_patched` restores first and then
  re-raises a raise of its body).
* Reading any other `H` key raises a message naming it (the old table answered `nil`).

A file is one case (`testing.run.inproc`); see [`../run/README.md`](../run/README.md).
