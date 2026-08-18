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
| `pubsub.init`             | Initialize variables  - run before calling pub/sub functions to populate required state (e.g., tables/schemas).  |
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
- It stays a raw assignment rather than a `di.handlers` registration because the modularisation plan
  classifies `di.pubsub` as **standalone** — it takes no injected dependencies, so reaching
  `di.handlers` would contradict its own tier.

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
