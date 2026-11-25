# state

Snapshot the whole state of a q process and report what changed between two snapshots. A
snapshot holds every namespace, variable and view, plus the system settings. Use it to see what a
script, a module load or a function call left behind: new globals, overwritten `.Q` settings,
namespaces created or deleted, attributes added, `\c` or `\t` changed.

```q
q)st:use`di.state
q)st.setstate`before
q)qsp:use`di.qsp
q)\l /data/hdb
q)st.setstate`after
q)select ns,name,kind,change from st.collapse st.comparestate[`before;`after]
ns    name        kind change
------------------------------
.     accounts    var  added
.     date        var  added
.     qsp         var  added
.     sym         var  added
.     trades      var  added
..
.Q    .Q.pf       var  added
.Q    .Q.pt       var  changed
..
.Q.m  .Q.m.M      var  changed
.m.di .m.di.0qsp  ns   added
\     \cd         sys  changed
```

## Capturing

| Function | Description |
|----------|-------------|
| `setstate[name]` | Capture the current state under `name` (a symbol atom). The capture before it becomes the previous one, for `lastchanges`. |
| `setfingerprint[name]` | The same, but saves a fingerprint (see below) that holds no references to the process's values. |
| `addstate[name;state]` | Save a state taken elsewhere under `name`: for example, a fingerprint loaded from disk or fetched from another process. |
| `statenames[]` | Names of the saved states, oldest first. |
| `dropstate[name]` | Forget a saved state. |
| `getstate[]` | The current state, for `diff` or `fingerprint`. Nothing is saved. |
| `fingerprint[state]` | A state with each value replaced by its fingerprint. |

The module captures one state when it loads, which `sincestartup` compares against.

A capture records:

- **namespaces**, top level and nested. The module's own namespace (`.m.di.0state`) is never
  captured, because its saved states change on every capture.
- **variables**, by fully qualified name, with their attributes recorded at the time of capture.
  q applies an attribute in place, so `` x:`s#x `` also changes any saved value of `x`; recording
  the attributes separately is how the change is seen.
- **views**, by the value they give. Capturing a view brings it up to date.
- **system settings**: `\c` `\C` `\d` `\e` `\g` `\o` `\p` `\P` `\s` `\t` `\T` `\W` `\z` and
  `\cd`. Not `\S`: the random seed moves every time `?` is used. `sincestartup` does not compare
  `\d` or `\e`, because they hold other values while a module loads.

## Reports

| Function | Description |
|----------|-------------|
| `comparestate[name1;name2]` | What changed from saved state `name1` to `name2`. |
| `lastchanges[]` | What changed between the last two captures. |
| `sincelast[]` | What changed since the last capture. Nothing is captured. |
| `sincestartup[]` | What changed since the module loaded. |
| `diff[state1;state2]` | What changed between two states, as `getstate` or `fingerprint` return them. |
| `around[f;args]` | Apply `f` to the list `args`, and return `` `result`changes ``: what `f` gave back, and what it changed. |
| `collapse[report]` | The report with each namespace that appeared or disappeared folded to its one `ns` row. Its contents are dropped, leaving the new and deleted namespaces plus every change to what was already there. This is usually the view to read first. |
| `summary[report]` | One row per namespace, counting each kind of change. |

Each report has one row per change, sorted by `ns`, `kind` and `name`:

| Column | Type | Description |
|--------|------|-------------|
| `ns` | `symbol` | The namespace the name lives in: `` `. `` for root, `` `\ `` for system settings. |
| `name` | `symbol` | The fully qualified name, such as `.Q.pf`, `.m.di.0qsp` or `\c`. Root variables keep their bare name, such as `trades`. |
| `kind` | `symbol` | `` `ns `` for a namespace that appeared or disappeared, `` `var ``, `` `view ``, or `` `sys `` for a system setting. |
| `change` | `symbol` | `` `added ``, `` `removed `` or `` `changed ``. Only variables and views can be `changed`, and system settings are always `changed`. |
| `before` | any | The value in the first state, or `::` if it was not there. |
| `after` | any | The value in the second state, or `::` if it is gone. |

A value counts as changed if it no longer matches (`~`) or its attributes differ.

`summary` has the columns `nsadded`, `nsremoved`, `added`, `changed` and `removed`, keyed by `ns`.

```q
q)r:st.around[{[x] .cache.last:x;:x*2;};enlist 21]
q)r`result
42
q)select ns,name,kind,change from r`changes
ns     name        kind change
------------------------------
.      .cache      ns   added
.cache .cache.last var  added
```

## Fingerprints

A fingerprint describes each value as `(type;count;attributes;serialised size;md5)`. It holds no
references to the process's values, so it is small and can be saved with `set`. A saved state
otherwise keeps alive every value it refers to, including tables that have since been replaced.

When either side of a `diff` is a fingerprint, both are compared as fingerprints, so a
fingerprint can be compared with the live process:

```q
q)st.setfingerprint`morning
q)/ ... later
q)st.sincelast[]
```

The same works across restarts or between processes. Save `st.fingerprint st.getstate[]` with
`set` in one process, load it with `get` in another, then `addstate` or `diff` it there.

The md5 is left out for values over 10MB serialised, so a change to a big value that keeps its
type, count, attributes and size goes unseen. A partitioned or splayed table is fingerprinted as
its in-memory form, so changes to its data on disk are not seen.

## Leaving names out

| Function | Description |
|----------|-------------|
| `ignore[names]` | Never report these names. A name that is a namespace hides everything below it: `` st.ignore`.m `` hides every module's internals, and `` st.ignore`. `` hides root variables. Returns what is ignored. |
| `unignore[names]` | Report these names again. Returns what is ignored. |
| `ignored[]` | Every name left out of the reports. |

`.z.ex` and `.z.ey`, which the debugger sets at a `q))` prompt, are ignored by default. A name is
left out of a report when the report is made, so `ignore` also applies to states that were
captured earlier.

## Checking modules

`bin/check.q` checks that loading a module leaves nothing behind but its own namespace under `.m`
and the variable it is loaded into. It loads each module in a fresh q, between two captures, and
lists anything else the load changed. That covers globals, other namespaces, `.z` handlers and
system settings such as `\t` or `\cd`. Only the load is checked: a module's `init` is not called.

```sh
q di/state/bin/check.q -q                      # every module beside this one, in kdbx-modules/di
q di/state/bin/check.q -dir path/to/di -q      # every module in another directory
q di/state/bin/check.q -mod qsp os -q          # only these
```

```
module            result
clienttracking    2 change(s)
k4unit            1 change(s)
qsp               clean
..

== clienttracking
ns name     kind change
-----------------------
.  .clients ns   added
.  .dotz    ns   added
```

It exits 1 if any module changed something or would not load, so it can run in CI.

## Notes

- A saved state holds a reference to every value the process had when it was taken. q shares
  values rather than copying them, so a capture is cheap. But a table that is later replaced
  stays in memory while a saved state still refers to it. Use `dropstate` to let it go, or save a
  fingerprint instead.
- A report compares values with `~`, so a large table that changed is compared in full.

## Tests

```sh
q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.state
```
