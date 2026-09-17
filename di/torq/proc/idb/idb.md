# di.torq.proc.idb

The intraday database process type: mounts the **wdb's working directory** (the same
`savedir` that `di.torq.proc.wdb` incrementally writes/appends into during the day, before its
end-of-day sort + move into the hdb), independently loads the **hdb's sym domain** so the
mounted tables' symbol columns resolve correctly, and exposes a remotely-triggerable reload -
so queries can see today's data before it lands in the hdb. Started by `di.torq` through the
same `init[config;deps]` convention as every other built-in proctype.

## Design

### Why point at the wdb's working directory, not the hdb

`di.torq.proc.wdb` deliberately writes through a permanent working directory and only **moves**
each table into the hdb once it is complete and sorted (see wdb.md, "Why a separate working
dir + move"). That move is what keeps the hdb always either absent-or-complete for a given
partition — a mid-day crash can't leave partial data there. The trade-off is that the hdb
alone can't answer "what happened so far today"; `di.torq.proc.idb` fills that gap by mounting
the wdb's working dir directly, accepting that data there may be unsorted and can, in the
narrow window of an in-flight flush, be incompletely appended (see "Known gaps").

### `resolvedatadir[dir]`

Resolves a possibly-relative `savedir:`/`hdbdir:` setting to an absolute path: an absolute
path is used as-is, a relative one is joined against `TORQXDATAHOME` (falling back to
`TORQXAPPHOME`). Both values must resolve to the **same absolute paths** as the wdb's own
`savedir`/`hdbdir` config - idb and wdb are pointed at the same two physical directories, not
connected to each other over IPC. Unlike `di.torq.proc.wdb`'s own `resolvedir`, this doesn't
take a `base` parameter - idb has no apphome-relative config (no `sortcsv` equivalent), so
both its directory settings always resolve against `TORQXDATAHOME`. Its body is otherwise
identical to `di.torq.proc.wdb`'s `resolvedir`, **not** `di.torq.proc.hdb`'s: the wdb's own
`savedir`/`hdbdir` TOML values arrive as a plain string with no leading colon (e.g. `"wdb"`),
unlike `di.torq.proc.hdb`'s `dir` convention (`":hdb_empty"`) - `resolvedatadir` strips a
leading colon if present rather than assuming one, so it normalises a `.q`-settings symbol
(`` `:wdb ``) and a colon-less `.toml` string (`"wdb"`) to the same result the wdb itself
would resolve.

### `symfile[]` / `loadsym[]`

The wdb enumerates every flushed table's symbol columns against **its `hdbdir`**, not
`savedir` (`di.torq.proc.wdb`'s `flushtable`, `` .Q.en[.z.m.hdbdir;...] ``) - live, on every
flush, not just at EOD. So the working-partition tables idb mounts carry symbol columns that
are true kdb+ enumerations (foreign keys) against `hdbdir/sym`, and reading them back
correctly requires that **same** `sym` domain to exist in idb's own session - without it, a
symbol column reads back as raw integer indices instead of symbols. `symfile[]` is the fixed
path to that file (not partition-scoped, unlike `partitiondir[]` - the wdb enumerates every
day against the same `hdbdir/sym`); `loadsym[]` reads it into the root `sym`,
called from `init` (always) and from `reload[]` (only when the file has changed - see
`symfilehaschanged[]` below), in both cases before `domount[]`, matching legacy TorQ's own
`loadsym`-before-`loadidb` order in `loaddb`.

### `symfilehaschanged[]`

The wdb calls `.idb.reload[]` after **every** intraday flush that wrote anything, but `.Q.en`
only rewrites `hdbdir/sym` when it meets a symbol the domain doesn't already have. On a busy
day the overwhelming majority of those reloads therefore have nothing new to read, so
**`reload[]` gates its `loadsym[]` call** on `symfilehaschanged[]` - a port of legacy TorQ's
function of the same name (`TorQ/code/processes/idb.q`), including its
record-the-new-size-on-detect behaviour. It turns the common case from a full read of a
domain that grows all day into a `hcount` stat.

The gate lives in the **caller**, not in `loadsym[]`, which stays an unconditional force-load -
the same split legacy TorQ has between `loaddb` (force: startup and rollover) and
`intradayreload` (gated). `loadsym[]` records the size it just read on the way out, so the next
check compares against what is actually in the root `sym` rather than against whatever a
previous `init` recorded. `domount[]` is *not* gated - see "Mounting vs legacy"
below.

It compares **size**, not modification time: the sym file only ever grows (`.Q.en` appends), so
a size change is exactly a content change, while mtime granularity can miss two writes within
the same second. `hcount` is trapped to `0` rather than left to throw, and the guard is checked
*after* `loadsym[]`'s existence test - so a sym file appearing for the first time is always
read, since a missing file stats as `0`, which is also `symsize`'s initial value.

`init` calls `loadsym[]` directly, so it always reads the file it has just been pointed at
rather than trusting a size recorded against a previous init's `hdbdir`.

`loadsym[]` uses legacy TorQ's plain `load`, which **replaces** root `sym` with the file's
contents rather than merging into it. The file is the enumeration domain and the on-disk columns
are integer positions in it, so root `sym` has to match its order exactly; a union against a `sym`
that had drifted out of step would keep the wrong order and resolve every symbol column to the
wrong value, silently.

`load` is one of the few writes that does **not** need the `` @[`.;...] `` root anchoring the rest
of this tier uses - it names the variable after the file, and lands at root even when called from
inside a `use`-loaded module (verified directly; `sym` never appears in the module's private
namespace).

### Mounting vs legacy

Legacy TorQ gates its mount too - `` if[partitioncounthaschanged[];loadidb[]] `` - and in
`default` writedown mode that check is hard-wired to `0b` while a single partition exists, so it
effectively never remounts intraday; it just clears the row-count cache (`.Q.pn`). It can afford
that because it mounts the **db root** (`savedir`) as a partitioned database, and because its wdb
calls `filldb`/`initmissingtables` to pre-create every table's directory at partition start, so
no new table ever appears mid-day.

`di.torq.proc.idb` mounts the single **date directory** (`savedir/<date>`), which gives plain
splayed tables at root, not a partitioned db - so there is no `.Q.pn` to invalidate. And
`di.torq.proc.wdb`'s `flushtable` creates a table's directory on its **first** flush, so tables do
appear mid-day. That is why `domount[]` runs unconditionally. Measured, for a mounted date dir:

| change on disk | visible without remount? |
| --- | --- |
| rows appended to an already-mounted table | **yes** |
| a table directory appearing for the first time | **no** |

So the unconditional remount is doing real work exactly in the case legacy engineered away.

### `currentpartition[]` / `partitiondir[]`

Unlike the hdb (one fixed dir, mounted once and reloaded in place), the wdb's `savedir` only
ever holds the **current** day's not-yet-moved data - once a day is flushed and moved to the
hdb, its directory under `savedir` is removed (`di.torq.proc.wdb`'s `movetohdb`/`endofday`). So
the idb can't just remount a fixed directory; it re-derives which date directory to mount
**every time** `init`/`reload[]` runs: a fixed `partition` config override if one was given,
else `.z.d` evaluated fresh on that call. This means a long-lived idb process that gets
reloaded - by the wdb, either after an intraday flush or at EOD (see wdb.md, "Intraday" /
"End of day") - after midnight automatically starts looking at the new day's directory, with
no restart needed.

### `init[config;deps]` / `reload[]` / `domount[]`

Requires only a `log` dependency (no timer/handlers registration of its own, matching
`di.torq.proc.hdb`). Resolves `savedir` and `hdbdir`, then both `init` and `reload[]` call
`loadsym[]` (see above), then the shared `domount[]`: it mounts `partitiondir[]` with
`` system "l ",dir `` and logs the tables
loaded **only if that directory currently exists** - otherwise it logs a warning and leaves
whatever was already loaded in place. The directory legitimately doesn't exist in two normal
windows: right after a wdb's EOD move (which `rm -rf`s the old day's now-empty working dir)
and before the new day's first intraday flush recreates it, and at idb startup if it starts
before the wdb has flushed anything at all yet. Without the guard, `system "l"` on a missing
directory throws - which would crash `init` before it even reached `set[`.idb.reload;reload]`,
leaving no reload entry point to recover with; guarding it means `init` always finishes and
publishes `reload`, so the very next `reload[]` (once the wdb produces data) picks it up
normally. Publishes `reload` at the real root name `.idb.reload` for the same reason
`di.torq.proc.hdb` publishes `.hdb.reload` - `use`-loading this module compiles it into a private,
mangled namespace, so a remote `` .idb.reload[] `` call needs a plain root-level entry point
to exist (torq-developer skill, Rule E3). `reload[]` re-derives the partition dir (picking up
a new day, or newly-flushed data for today) before remounting.

## Dependency

`log` only.

## Config

| key | meaning |
|---|---|
| `savedir` | the wdb's working directory - relative (resolved against `TORQXDATAHOME`, falling back to `TORQXAPPHOME`) or absolute. Must match the wdb's own `savedir` config. |
| `hdbdir` | the hdb directory the wdb enumerates symbols against - relative or absolute, same resolution as `savedir`. Must match the wdb's own `hdbdir` config. Used only to load `hdbdir/sym`; idb never mounts anything else under it. |
| `partition` (optional) | fixed date to mount, overriding the default of "today" (`.z.d`, re-evaluated on every `init`/`reload[]`). Mainly for tests / point-in-time inspection of a specific day; a live idb normally omits this. |

## Usage

```q
q)idb:use`di.torq.proc.idb
q)lg:use`di.util.log
q)logdep:`info`warn`error!(lg`info;lg`warn;lg`error)
q)cfg:`savedir`hdbdir!(`$":/tmp/di_idb_readme_demo";`$":/tmp/di_idb_readme_hdb_demo")
q)idb[`init][cfg;enlist[`log]!enlist logdep]
2026.07.09D12:41:24.703763000 INFO init mounting idb from :/tmp/di_idb_readme_demo/2026.07.09
2026.07.09D12:41:24.703850000 WARN loadsym no sym file at /tmp/di_idb_readme_hdb_demo/sym yet - symbol columns may not resolve
2026.07.09D12:41:24.703897000 INFO domount loaded tables: trade
q)tables[]
,`trade
q)delete trade from `.
q).idb.reload[]
2026.07.09D12:41:24.703928000 INFO reload reloading idb from :/tmp/di_idb_readme_demo/2026.07.09
q)tables[]
,`trade
```

(Called via `idb[`init]`, not `idb.init` - dot-syntax on a module dict returned by a `use` call
in the same session/frame is unreliable in this kdb-x build; see `test.csv`'s comment and
`di.torq`'s own `buildlogdep` note for the same caveat elsewhere. `.idb.reload[]` is unaffected
- it's a plain root function, not accessed through the module dict.)

In the real sample app, `di.torq` builds `config`/`deps` from the settings cascade and calls
`(m`init)[config;deps]` itself (`torq.q`'s `startbuiltin` - bracket-indexed, same reasoning as
above) when `proctype` is `` `idb ``. Pointing an idb's `savedir` at
the **same** directory as a running wdb's `savedir` (matching config value, resolved to the
same absolute path) is what makes it see that wdb's intraday writes.

## Known gaps (v1)

- **No wdb handshake at startup.** Legacy TorQ's idb queries the wdb over IPC for its own
  config (`setparametersfromwdb`: `savedir`/`hdbdir`/`currentpartition`/`writedownmode`) and
  blocks startup on `` .servers.startupdepcycles[`wdb;...] `` until a wdb is reachable.
  `di.torq.proc.idb` is config-driven only - its `savedir`/`partition` come from its own
  settings, which must be kept in sync with the wdb's `savedir` by hand - and has no IPC
  dependency on the wdb at all: it mounts whatever is on disk regardless of whether a wdb is
  running (see `init[config;deps]` above).
- **No self-registration or attribute-based gateway routing.** Legacy TorQ's idb registers
  itself with the wdb (`` .servers.registerfromdiscovery ``) and publishes
  `` .proc.getattributes `` (`` `partition`tables!(.idb.currentpartition;tables[]) ``) so a
  gateway can route queries to whichever idb currently holds the relevant partition/tables.
  `di.torq.proc.idb` does neither: the wdb finds it the same static way it finds every other
  peer (`process.csv` + `idbtypes` in `CONNECTIONS`), and there is nothing to register with a
  gateway anyway - `di.torq.proc.gateway` v1 has no backend attribute-reporting plumbing yet
  for *any* backend type, not just idb (see gateway.q's "EMPTY attributes" note).
- **`writedownmode`-aware layout, and the `partbyenum`/`partbyfirstchar` query-mapping
  helpers** (`maptoint`/`mapfctoint` in `TorQ/code/processes/idb.q`). Legacy TorQ's idb picks
  its mount directory differently depending on the wdb's active writedown mode, and ships
  helpers for querying a `partbyenum`/`partbyfirstchar`-mapped sym column. Moot while
  `di.torq.proc.wdb` only implements the classic `default` writedown mode (see wdb.md, "Not
  included") - would need porting together if wdb ever grows the advanced modes.
- **No sort/attribute awareness.** The idb mounts whatever is on disk, unsorted, exactly as the
  wdb wrote it (matching `di.dbwrite`'s appended-not-sorted intraday writes).
- **`domount[]` is never gated**, unlike legacy TorQ's `loadidb`, and there is no `.Q.pn`
  row-count-cache reset. Both follow from mounting a single date directory of splayed tables
  rather than a partitioned db root - see "Mounting vs legacy" above. The remount is cheap
  (`\l` of one directory) and a reload is driven by the wdb, not a timer.
- **Read-during-write race.** The wdb's per-table flush (create-or-append) is not atomic
  from a reader's point of view; a reload that lands mid-flush could see a partially
  appended table. Same class of risk legacy TorQ's idb accepts for intraday data - only the
  hdb (post-move) is guaranteed complete-or-absent.
- **One directory, one mount** - no partitioned multi-database layout beyond what a plain
  `` \l `` already gives (matching `di.torq.proc.hdb`'s equivalent gap).

## Testing

`test.csv`/`test.q` (k4unit) cover: init failing without a `log` dependency, init failing
without a `savedir` setting, init failing without an `hdbdir` setting, init with an absolute
`savedir` + `hdbdir` + fixed `partition` override, the loaded root `sym` matching the fixture
domain and the fixture's genuinely-enumerated `name` column resolving to real symbols (not raw
indices - the exact failure mode `loadsym[]` exists to prevent), the published `.idb.reload[]`
actually remounting after a table is dropped, init with a relative `savedir` (exercises
`resolvedatadir`'s `TORQXAPPHOME` join), init with `savedir`/`hdbdir`/`partition` as plain q
strings (simulates `.toml`-sourced settings), init with no `partition` override (must derive
`.z.d`), and init/reload with a `partition` whose directory doesn't exist on disk (must warn,
not throw, and recover on the next reload once data appears). The fixture's `widgets` table is
built with `.Q.en` and written with a trailing-slash path (`` ` sv (path;`) ``, matching
`di.torq.proc.wdb`'s own `flushtable`) so it's a genuine splayed, enumerated table on disk, not
a flat serialised file - a bare `` `:dir/widgets `` (no trailing slash) silently "worked" with
the old non-enumerated fixture but throws `'type` on mount for a real enum column. Every
`idb[...]` call in `test.csv` is bracket-indexed, not `idb.xxx` - see the Usage section above.
Run in a fresh q session (this suite calls `setenv`, so don't interleave it with other
modules' tests in one shared process):

```q
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.torq.proc.idb
```
