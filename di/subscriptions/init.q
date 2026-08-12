/ di.subscriptions - subscribe a process (rdb, wdb, chained tp) to a tickerplant: define the
/ subscribed tables at root from the tickerplant's schemas, replay the pre-subscription tp log
/ exactly once, then let live updates flow through the root upd.
/ ported from TorQ's code/common/subscriptions.q (.sub). the caller owns the connection.

\l ::subscriptions.q

/ module version, read from the VERSION file rather than hardcoded in the implementation, so a
/ release bump touches one plain-text file.
/ NB `version` STAYS in the export: di.depcheck reads it from the export dict (checkdepversion),
/ and reports "exports no version" - failing the dependency check - if a module drops it
version:first read0`:::VERSION

/ NB: export:([...]) EVALUATES each name, so it can only list names that already exist.
/ init and getapimeta are framework plumbing di.torq calls by convention; every other name here has
/ a getapimeta row, which the test suite asserts
export:([init;teardown;version;getapimeta;subscribe;resubscribe;unsubscribe;subscribed;getsubscriptions])
