# History: from the original qsp

`di.qsp` began as a port of qsp, a set of q scripts with global state, to a
KDB-X module. This page records what changed in the port, and how the module
did against the original's own test suites. [../CHANGELOG.md](../CHANGELOG.md)
has every change since.

## What changed


**Reimagined:**
- Global mutable state became a policy **value**, with config as part of it.
  Gone with it: `clearpolicy`, `enabled`, the global settings, and the
  placeholder row the grants table needed to keep its column types.
- Tables are described with `meta` instead of `setattributes` / `settypes`.
- `USER` and `NOW` resolve at rewrite time. There is no `.qsp.currentuser`
  global, so nothing is left in the tree that a query could reach.
- Audit decisions follow from the stage that refused. A fault carries an
  unforgeable marker instead of a global flag. The log keeps the tree rather
  than a `-3!` string, which `\c` truncated.
- A filter function's empty result refuses the query instead of meaning every
  row; it returns `qsp.ALL` for every row.
- `serve` keeps the handlers it found and evaluates through them, and
  `unserve` puts them back. The original replaced them.

**Dropped:** TorQ `.lg` / `.dotz` hooks, `limits`, the semantic layer, demo,
data generator and evaluation harness. They belong to an application, not the
module.

**Fixed along the way:**
- **Any login was accepted.** qsp trusted `.z.u`, and q accepts any name with
  any password by default. Logging in as `compliance1`, or as the group name
  `compliance`, gave that access. `serve` now installs a `.z.pw` that admits
  only the policy's users and gateway logins, and a gateway may name only a
  user. Passwords still need `-U` or your own `.z.pw`.
- **The sort of `select[n;>c]` was never checked.** This was found by
  reviewing test coverage, and was in the walker from this repository's first
  commit. The walker treats a one-item list as data. parse puts the sort in
  one, but q evaluates it. `select[>leakfn size]` called a global,
  `select[>pnl]` ordered rows by a hidden column, and `select[<5000]` opened a
  connection. The sort is now walked in the columns q evaluates it against,
  and its grade is guarded.
- **`scaffold` wrote into a database.** The setup guide's relative
  `scaffold["policy";...]`, run from an HDB console, put `policy/` inside the
  HDB, which then failed to load. It now refuses a database or a partition of
  one, and the guide gives an absolute path.
- `exec ... by sym` was normalised to a keyed table. It now returns q's own
  dictionary shape.
- `select distinct` was refused. It is now permitted.
- The `` `$"\000..." `` markers were all the null symbol, because a symbol
  stops at a NUL byte.
- A refused function is now named in the refusal (`function not permitted:
  system`), so a query generator can repair the query.
- `qsp.f.notin` builds a two-item constraint (`not` and its argument), which
  the filter check refused. It now loads like any other filter. Found by the
  files suite.

## Against the original suites

The module was also run against the original qsp's own suites through a
test-only shim of the old global API:

| suite | result |
|---|---|
| run | 202/204: the two "differences" are the `exec ... by` fix above |
| attack | 255/255 bypass attempts refused |
| attributes | 64/65: the module returns a typed empty dictionary where the old test expects `()!()` |
| runtime | 31/31: three assertions on the removed `.qsp.currentuser` global skipped |
| partition | 26/31: the five misses inspect the old `gwserver.q` demo script |
