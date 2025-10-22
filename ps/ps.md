[ps.md](https://github.com/user-attachments/files/22662173/ps.md)
# Publish/Subscribe Utilities
> **Note:** Initial documentation draft (to be refined post-review).


A lightweight kdbx-compatible package provides a list of functions to help users to subscribe to STP with custom data requirements, and publish data from the STP to downstream accordingly. 



### Features:
- Unified APIs for subscribe and publish.
- Flexible filtering: limit by tables, symbols, or user-defined predicates.
- String-based subscriptions so non-kdb users can subscribe via simple strings.

---

### Subscription Management:


| Name         | Type     | Purpose                                              |
| ------------ | -------- | ---------------------------------------------------- |
| `ps.reqalldict`   | dict     | Dictionary mapping each data table to its subscribers  |
| `ps.reqfilteredtbl`  | table    | Table mapping each data table to its subscribers and their custom requirements  |


---

### API (Key Functions):


**ps.subscribe**

```q
subscribe to STP with/without fitlers. The function takes two arguments: tables and filters, user can specify which table or list of tables to subscribe to, default list which is all tables on top level of STP will be subscrbied if left blank; filters can be a subset of symbols or custom conditions in the form of table created by user, see examples.
```


**ps.substr**

```q
allows non-kdb users to subscribe via strings containing tables and symbols, see examples.
```


**ps.substrf**

```q
allows non-kdb users to subscribe via strings of custom conditions, see examples.
```


**ps.publish**

```q
publish data with/without filters. The function takes two arguments: t and x, which are table name and data to be published respectively. when no table specified, the function will scan both reqalldict and reqfilteredtbl, when table name is found/subscribed, publish to downstream subscribers accordingly.
```

---

### Utilities:
| Function            | Description                                                                 |
|---------------------|-----------------------------------------------------------------------------|
| `ps.add`           | Add a subscriber handle to the “request-all” dictionary.                    |
| `ps.addfiltered`   | Register a subscription with custom filter conditions.                      |
| `ps.delhandle`     | Remove a subscriber handle from the request-all registry.                   |
| `ps.delhandlef`    | Remove a subscriber handle from the request-filtered registry.              |
| `ps.endd`          | Broadcast an end-of-day event to all subscribers (requires `endofday`).     |
| `ps.endp`          | Broadcast an end-of-period event to all subscribers (requires `endofperiod`).|
| `ps.extractschema` | Return a table’s schema.                                                    |
| `ps.suball` | Subscribe to all tables.                     |
| `ps.subfiltered` | Subscribe to tables with filters.                                                   |
| `ps.addfiltered` | Subscribe to tables with custom conditions.               
| `ps.addsymsub` | Subscribe to tables with a list of symbols (or one symbol).                                              |
| `ps.closesub` | Remove handle upon connection close.                 

---

### Example: 
```q
q)ps:use`ps

q)ps.subscribe[`;`]
q)ps.subscribe[`;`AAPL`GOOG]
q)ps.subscribe[`trade;`AAPL]
q)ps.subscribe[`trade;`]

q)conditions:([tabname:`trade`quote] filts:("";"bid>100,bid<200"); columns:("time,sym,price";""))
q)ps.subscribe[`;conditions]

q)ps.substr["trade";"GOOG,AAPL"]
q)ps.substrf["quote";"bid>50.0";"time,sym,bid"]

```
---
## Notes:

- By default, all tables on top level of STP are available for subscription, to change that, user can provide specified list of tables using `ps.subtables` on start up.
- The package initializes with defined list of tables to subscribe to and fetches their schemas and columns for use, and set `ps.initialized` to be True. 


