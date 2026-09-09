/ di.tickerplant - tick-capture: log and publish incoming updates, roll at end of day
/ hard dependencies - imported here as module-local handles (before the impl loads), used by tickerplant.q
pubsub:use`di.pubsub
eodtime:use`di.eodtime
tplog:use`di.tplog
\l ::tickerplant.q
/ module version, read from the VERSION file (one plain-text file to bump per release). read
/ module-relative at load (`:::` resolves to di/tickerplant) and BEFORE export, since export:([...])
/ evaluates each name; version stays in the export so di.depcheck reads it from the export dict.
/ trim, and fail LOUD on a missing/unreadable/empty VERSION, rather than a bare `first read0`:
/ a raw OS error names no module, and an empty or whitespace-padded value is worse than an error -
/ di.depcheck compares versions as STRINGS, so padding silently breaks the comparison and an empty
/ value reads as "exports no version", failing every dependent module's check for a reason that
/ points nowhere near the real cause. same shape as di.rdb, di.dbwrite and di.eodtime
version:@[{trim first read0 x};`:::VERSION;{'"di.tickerplant: VERSION file missing or unreadable"}];
if[0=count version;'"di.tickerplant: VERSION file is empty"];
export:([init;teardown;upd;subscribe;subdetails;tablelist;endofday;getcounts;gettables;getapimeta;version])
