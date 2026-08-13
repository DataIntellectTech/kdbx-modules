/ di.tickerplant - tick-capture: log and publish incoming updates, roll at end of day
/ hard dependencies - imported here as module-local handles (before the impl loads), used by tickerplant.q
pubsub:use`di.pubsub
eodtime:use`di.eodtime
tplog:use`di.tplog
\l ::tickerplant.q
/ module version, read from the VERSION file (one plain-text file to bump per release). read
/ module-relative at load (`:::` resolves to di/tickerplant) and BEFORE export, since export:([...])
/ evaluates each name; version stays in the export so di.depcheck reads it from the export dict
version:trim first read0`:::VERSION
export:([init;upd;subscribe;endofday;getcounts;gettables;getapimeta;version])
