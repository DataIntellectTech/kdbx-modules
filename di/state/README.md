# di.state

A KDB-X module that snapshots the whole state of a q process and tells you what changed between
two snapshots.

A snapshot holds every namespace, variable and view, each variable's attributes, and the system
settings (`\c`, `\P`, `\t`, `\cd`, ...). Diffing two snapshots gives one row for each name that
was added, removed or changed. Use it to answer questions like:

- *What did loading that script leave behind?*
- *Does this function do anything besides return its result?*
- *Why does UAT behave differently from prod?*
- *Has anyone redefined a function in this process while it was running?*
- *Does our module leak globals when it loads?*

```q
q)st:use`di.state
q)st.setstate`before
q)\l legacyutils.q
q)st.setstate`after
q)select ns,name,kind,change from st.collapse st.comparestate[`before;`after]
ns name     kind change
------------------------
.  .lu      ns   added
.  fmt      var  added
.  lastload var  added
.z .z.pg    var  added
.z .z.zd    var  added
\  \P       sys  changed
\  \c       sys  changed
```

## Installation

`di.state` follows the [kdbx-modules](https://github.com/DataIntellectTech/kdbx-modules) layout.
It is loaded as `di.state`, so put this directory at `di/state` in a folder on your `QPATH`:

```bash
# alongside the other Data Intellect modules
cp -r state ~/kdbx-modules-main/di/state
export QPATH=${QPATH}:~/kdbx-modules-main/

q
q)st:use`di.state
q)st.version
"0.1.0"
```

You need KDB-X, for `use`. `state.q` is an older standalone version of the same idea that you can
load with `\l` into a plain q process. It defines everything under `.state` and has no views,
system settings, attributes or fingerprints.

## Quick start

```q
q)st:use`di.state

/ capture, do something, capture, compare
q)st.setstate`before
q)/ ... load a script, call a function, apply a patch ...
q)st.setstate`after
q)st.comparestate[`before;`after]

/ shortcuts
q)st.lastchanges[]        / between the last two captures
q)st.sincelast[]          / since the last capture, without capturing
q)st.sincestartup[]       / since the module was loaded

/ one function call: what it returned, and what it changed
q)r:st.around[{[x] .cache.last:x;:x*2;};enlist 21]
q)r`result
42
q)r`changes

/ make a report easier to read
q)st.collapse rpt         / fold each new or deleted namespace to one row (read this first)
q)st.summary rpt          / count each kind of change per namespace

/ hide noise
q)st.ignore`trade`.m      / a namespace name hides everything below it
```

## Examples

Each script in [`examples/`](examples) runs on its own and prints its output. Run them from the
repo root with `di.state` on your `QPATH`.

| Example | Use case | Functions used |
|---------|----------|----------------|
| [`01_auditscriptload.q`](examples/01_auditscriptload.q) | **Audit a script before trusting it.** Loads an inherited utility script between two captures. It turns out to wrap `.z.pg`, change `.z.zd` compression for every write, change `\P` and `\c`, and leave root globals behind. | `setstate` `comparestate` `collapse` `summary` |
| [`02_functionsideeffects.q`](examples/02_functionsideeffects.q) | **Find hidden side effects in a function.** An end-of-day routine that should only return a summary also leaves a global, empties `trade` and stops the timer. Also shows a one-line `pure` check to use in tests. | `around` |
| [`03_configdrift.q`](examples/03_configdrift.q) | **Compare config across processes or restarts.** Saves a fingerprint of a "prod" process to disk, then compares a "uat" process against it. Run it twice, with `-save` and then with `-compare`. | `fingerprint` `addstate` `setfingerprint` `ignore` |
| [`04_changemonitor.q`](examples/04_changemonitor.q) | **Watch a live process for changes.** A timer logs every function redefinition, settings change or stray global, while ignoring a data table that grows on every tick. Each check is saved as a fingerprint, so the monitor holds no references to old values. | `sincelast` `setfingerprint` `ignore` |

```bash
q examples/01_auditscriptload.q -q
q examples/02_functionsideeffects.q -q
q examples/03_configdrift.q -save /tmp/prod.fp -q
q examples/03_configdrift.q -compare /tmp/prod.fp -env uat -q
q examples/04_changemonitor.q -q
```

Output from example 02:

```
== what eod changed
ns name        kind change
---------------------------
.  lastsummary var  added
.  trade       var  changed
\  \t          sys  changed

== pure checks
vwap is pure: 1
eod is pure:  0
```

Output from the uat run of example 03:

```
== differences from the reference process
ns   name         kind change
------------------------------
.cfg .cfg.alerts  var  removed
.cfg .cfg.debug   var  added
.cfg .cfg.env     var  changed
.cfg .cfg.timeout var  changed
\    \t           sys  changed
```

## API at a glance

The full reference is in [state.md](state.md).

| Capture | |
|---------|-|
| `setstate[name]` | Capture the current state under `name`. |
| `setfingerprint[name]` | Capture a fingerprint, which holds no references to values. |
| `addstate[name;state]` | Save a state taken elsewhere, such as one loaded from disk or fetched over IPC. |
| `getstate[]` / `fingerprint[state]` | Get a state, or a fingerprint of one, without saving it. |
| `statenames[]` / `dropstate[name]` | List saved states, or forget one. |

| Report | |
|--------|-|
| `comparestate[name1;name2]` | Compare two saved states. |
| `lastchanges[]` / `sincelast[]` / `sincestartup[]` | Compare against the last captures, or against the state at load time. |
| `diff[state1;state2]` | Compare any two states, including fingerprints. |
| `around[f;args]` | Run `f . args` and return `` `result`changes ``. |
| `collapse[report]` / `summary[report]` | Fold new namespaces to one row, or count changes per namespace. |

| Filter | |
|--------|-|
| `ignore[names]` / `unignore[names]` / `ignored[]` | Leave names out of reports, or put them back. The filter is applied when a report is made, so it also applies to states captured earlier. |

A report is a table with the columns `ns`, `name`, `kind` (`` `ns ``, `` `var ``, `` `view `` or
`` `sys ``), `change` (`` `added ``, `` `removed `` or `` `changed ``), `before` and `after`. A
variable counts as changed if its value no longer matches (`~`) or its attributes differ.

## Checking that modules load cleanly

`bin/check.q` loads each module in a fresh q between two captures. It reports anything the load
changed besides the module's own namespace under `.m` and the name it was loaded into: globals,
other namespaces, `.z` handlers, and system settings. It exits 1 if any module is dirty or fails
to load, so you can run it in CI.

```bash
q bin/check.q -q                             # every module beside this one
q bin/check.q -dir path/to/di -q             # every module in another directory
q bin/check.q -dir path/to/di -mod qsp os -q # only these
```

```
module            result
clienttracking    2 change(s)
memstats          clean
timer             clean
```

## Things to know

- **Saved states keep values alive.** A capture is cheap because q shares values rather than
  copying them. But a table that is later replaced stays in memory while a saved state still
  refers to it. Use `dropstate`, or capture fingerprints instead.
- **Fingerprints tell you *that* something changed, not *what* it changed to.** Each value is
  stored as `(type;count;attributes;serialised size;md5)`. Values over 10MB serialised get no
  md5, so a same-size change to a large value goes unseen. Partitioned and splayed tables are
  fingerprinted in their in-memory form, so changes to their data on disk are not seen.
- **Reports compare values with `~`**, so a large table that changed is compared in full. Use
  `ignore` on hot data tables, as example 04 does.
- **Some names are never reported.** The module's own namespace is never captured. `.z.ex` and
  `.z.ey`, which the debugger sets, are ignored by default. `\S` (the random seed) is not
  captured.

## Tests

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.state
```

## Layout

```
init.q        the module
state.md      full reference documentation
test.csv      k4unit tests
VERSION       module version, exposed as st.version
bin/check.q   checks that modules load cleanly
examples/     runnable use-case scripts, with the fixtures they load
state.q       older standalone (\l) version, under .state
```
