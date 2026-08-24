[pubsub.md](https://github.com/user-attachments/files/22662173/pubsub.md)
# Publish/Subscribe Utilities


A lightweight kdbx-compatible module provides a list of functions to help users to subscribe to processes (such as a [tickerplant](https://code.kx.com/q/architecture/tickq/)) with custom data requirements, and publish data from the the process to downstream processes accordingly. 



### Features:
- Unified APIs for subscribe and publish.
- Flexible filtering: limit by tables, symbols, or user-defined predicates.
- String-based subscriptions so non-kdb users can subscribe via simple strings.

---

### API (Key Functions):


**pubsub.subscribe**

```q
subscribe to a process with/without fitlers. The function takes two arguments: tables and filters, user can specify which table or list of tables to subscribe to, default list which is all tables on top level of the process will be subscrbied if left blank; filters can be a subset of symbols or custom conditions in the form of table created by user, see examples.
```


**pubsub.subscribestr**

```q
allows non-kdb users to subscribe via strings containing tables and symbols, see examples.
```


**pubsub.subscribestrfilter**

```q
allows non-kdb users to subscribe via strings of custom conditions, see examples.
```


**pubsub.publish**

```q
publish data with/without filters. The function takes two arguments: t and x, which are table name and data to be published respectively. when no table specified, the function will scan both reqalldict and reqfilteredtbl, when table name is found/subscribed, publish to downstream subscribers accordingly.
```

---

### Utilities:
| Function                  | Description                                                                  |
|---------------------------|------------------------------------------------------------------------------|
| `pubsub.setsubtables`     | Set a specified list of tables that are available for subscription.          | 
| `pubsub.getsubtables`     | Read the list of tables currently available for subscription - the counterpart to `setsubtables`, which replaces it. Empty until `init` has run. |
| `pubsub.callendofday`     | Broadcast an end-of-day event to all subscribers (requires `endofday`). **Unary**: `callendofday[date]`. |
| `pubsub.callendofperiod`  | Broadcast an end-of-period event to all subscribers (requires `endofperiod`). **Ternary**: `callendofperiod[currentperiod;nextperiod;data]`. |
| `pubsub.closesub`         | Remove handle upon connection close.                                         | 
| `pubsub.subclear`         | Publish tables and clear up the contents.                                    |
| `pubsub.init`             | Initialize variables  - run before calling pub/sub functions to populate required state (e.g., tables/schemas). `deps` is OPTIONAL - `pubsub.init[]` still works unchanged. An OPTIONAL `` `handlers `` key (a `di.handlers` register dict) additionally registers `closesub` as a named `.z.pc` observer, so `di.handlers.list[`.z.pc]` lists `` `pubsub `` explicitly - see Notes below.  |
| `pubsub.version`          | Module version string, read from the `VERSION` file. `di.depcheck` resolves a dependency's minimum from here. |
---

### Example: 
```q
q)pubsub:use`di.pubsub
q).u.sub:pubsub.subscribe
q).u.pub:pubsub.publish

q)pubsub.setsubtables[`trade`quote]
q)pubsub.init[]

q)pubsub.subscribe[`;`]
q)pubsub.subscribe[`;`AAPL`GOOG]
q)pubsub.subscribe[`trade;`AAPL]
q)pubsub.subscribe[`trade;`]

q)conditions:([tabname:`trade`quote] filts:("";"bid>100,bid<200"); columns:("time,sym,price";""))
q)pubsub.subscribe[`;conditions]

q)pubsub.subscribestr["trade";"GOOG,AAPL"]
q)pubsub.subscribestrfilter["quote";"bid>50.0";"time,sym,bid"]

```
---
## Notes:

- **The string entry points signal on failure.** `subscribestr` and `subscribestrfilter` exist so a
  non-kdb+ client can subscribe, and such a client cannot inspect a q result shape. A request that
  matched **no** table therefore signals rather than returning the error message as a value that
  merely reads like one. (The guard that previously did this could never fire: `errmsg` is built with
  `` `$ `` so it is a symbol, and `last` of either success shape is the schema list — never the `10h`
  string it tested for.) A *partial* match still returns, because those tables really were subscribed
  and signalling would report failure while leaving the client registered.
- **`.z.pc` chains, it does not replace.** This module installs a `.z.pc` handler at load so a
  dropped connection is deregistered (`closesub`). It captures whatever already owned the event and
  calls it afterwards. This matters: a bare `.z.pc:{closesub[x]}` silently destroyed every observer
  another module had already registered — measured against `di.handlers`, whose registry went on
  reporting the registration as live while it no longer fired, so the loss was invisible. The guard
  is asserted in `test.csv` by a child process that installs a handler *before* loading this module,
  which is the only way to observe load-time ordering.
- This raw assignment stays in place unconditionally (it runs at module **load** time, before `init`
  is ever called, so it cannot depend on anything `init` might later receive) — `di.pubsub` remains
  **standalone**: `init[]` with no argument, or with a `deps` dict that omits `` `handlers ``, behaves
  exactly as before.
- **`init`'s OPTIONAL `` `handlers `` key closes the one real gap the chaining above left**: chaining
  correctly preserved whatever `di.handlers` had already wired, but `di.pubsub`'s own hook stayed
  invisible to `di.handlers`' own registry (`di.handlers.list[`.z.pc]` never named `` `pubsub ``, even
  though it correctly fired). Passing a `` `handlers `` dep (`di.handlers`'s register dict, or the
  whole `di.handlers` module handle) additionally registers `closesub` as a named observer, so it now
  shows up there. The raw chain keeps running regardless — `closesub` is idempotent under a repeat
  call (`delhandle`/`delhandlef` are both remove-if-present), so a disconnect invoking it via both the
  raw chain and a `di.handlers` dispatch in the same tick is a harmless no-op on the second call, not
  a double-registration bug. Asserted in `test.csv` by a child process that inits `di.handlers` then
  `di.pubsub` with a `handlers` dep (subscribing through the **public** `subscribe` entry point, using
  the caller's real `.z.w` handle — not an internal `reqalldict` write and a fabricated handle, which
  would silently stop testing anything observable if that private variable's name or shape ever
  changed), and checks all three: registry visibility, `closesub` actually running, and the
  repeat-call idempotency.
- **`init` re-registers with `di.handlers` on *every* call that supplies `` `handlers ``, not just the
  first.** There is no one-shot latch: `di.handlers.register` is itself idempotent under a repeat call
  with the same name (`registersimple`'s `upsertphase` deletes then re-adds by name), so calling it
  again on a re-init costs nothing. A one-shot latch was tried and removed — it silently swallowed a
  *later* `init` call's registration attempt (including one meaning to re-point `di.pubsub` at a
  genuinely different `handlers` instance) with no error and no way to tell it never took effect,
  confirmed by a mock `handlers` dict that counts calls to `register` across two `init` calls. Omitting
  `` `handlers `` on a later call still leaves any earlier registration exactly as it was — `di.pubsub`
  never infers a deregistration from a bare re-init, the same as every other injected dep here.

- By default, all tables on top level of the process are available for subscription.
- The user should define the `.u.sub` and the `.u.pub` functions within the process.
- The module initializes with defined list of tables to subscribe to and fetches their schemas and columns for use. This is done via calling `init` function.

---

### End-of-day and end-of-period arity

These two broadcasts deliberately have **different arities**, which looks like an inconsistency and
is not:

| function | arity | broadcast |
|---|---|---|
| `callendofday` | unary | `` (`endofday;date) `` |
| `callendofperiod` | ternary | `` (`endofperiod;currentperiod;nextperiod;data) `` |

`callendofperiod` matches TorQ exactly - `code/common/pubsub.q:19` sends all three, and both shipped
subscribers (`code/rdb/endofperiod.q`, `code/wdb/writedown.q:52`) are `{[currp;nextp;data]}`.

`callendofday` deliberately **diverges** from TorQ, which sends `` (`endofday;x;y) ``. That second
argument is `processdata`; legacy's own rdb never reads it, and the shipped `.u.end` alias passes
`()!()` for it. Subscribers here are unary to match. Do not "fix" it for symmetry with
`callendofperiod` - doing so would turn every unary `endofday` subscriber into a projection.

That projection failure is the reason this matters, and it is completely silent. A subscriber whose
arity does not match what is broadcast is **partially applied**: q returns a projection, the body
never runs, and nothing throws, logs, or comes back to say so. `callendofperiod` was previously
unary, which failed both ways at once - a `callendofperiod[c;n;d]` call threw `'rank`, so a caller
following TorQ's contract could not call it at all, while the one-argument form silently no-opped
every ternary subscriber. Both measured; both covered by the suite, whose two assertions fail
against the unary implementation.
