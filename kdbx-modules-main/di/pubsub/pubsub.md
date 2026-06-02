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
| `pubsub.callendofday`     | Broadcast an end-of-day event to all subscribers (requires `endofday`).      |
| `pubsub.callendofperiod`  | Broadcast an end-of-period event to all subscribers (requires `endofperiod`).|
| `pubsub.closesub`         | Remove handle upon connection close.                                         | 
| `pubsub.subclear`         | Publish tables and clear up the contents.                                    |
| `pubsub.init`             | Initialize variables  - run before calling pub/sub functions to populate required state (e.g., tables/schemas).  |
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

- By default, all tables on top level of the process are available for subscription.
- The user should define the `.u.sub` and the `.u.pub` functions within the process.
- The module initializes with defined list of tables to subscribe to and fetches their schemas and columns for use. This is done via calling `init` function.
