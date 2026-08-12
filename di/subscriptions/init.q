/ di.subscriptions - subscribe a process (rdb, wdb, chained tp) to a tickerplant: define the
/ subscribed tables at root from the tickerplant's schemas, replay the pre-subscription tp log
/ exactly once, then let live updates flow through the root upd.
/ ported from TorQ's code/common/subscriptions.q (.sub). the caller owns the connection.

/ hard dependencies, per the modularisation plan's FRAMEWORK tier (di.subscriptions -> di.servers,
/ di.pubsub). imported before the implementation is loaded, matching di.eodtime's `use` of di.tz.
/   di.servers - getsubscriptionhandles resolves tickerplant handles off di.servers.SERVERS
/   di.pubsub  - the LOCAL publisher a chained or segmented tickerplant republishes through: with
/                republish set, subscribe hands the tables it defined at root to it, so this process
/                can serve them downstream (TorQ chainedtp.q:71-82, sctp.q:15-25)
/ NB the `use` runs at module LOAD, before init registers the .z.pc observer. that ordering is
/ load-bearing - see subscriptions.md
servers:use`di.servers
pubsub:use`di.pubsub

\l ::subscriptions.q

/ module version, read from the VERSION file rather than hardcoded in the implementation, so a
/ release bump touches one plain-text file.
/ NB `version` STAYS in the export: di.depcheck reads it from the export dict (checkdepversion),
/ and reports "exports no version" - failing the dependency check - if a module drops it
version:first read0`:::VERSION

/ NB: export:([...]) EVALUATES each name, so it can only list names that already exist.
/ init and getapimeta are framework plumbing di.torq calls by convention; every other name here has
/ a getapimeta row, which the test suite asserts
export:([init;teardown;version;getapimeta;subscribe;resubscribe;unsubscribe;subscribed;getsubscriptions;getsubscriptionhandles])
