/ di.segmentedtp - segmented tickerplant: five log-naming modes, three batch/publish modes, per-table
/ custom logging assignment and a dedicated on-disk log-metadata table. sibling of di.tickerplant, not
/ derived from it - see segmentedtp.md for the naming/batch mode reference and the design notes on
/ where this module's behaviour was corrected against legacy rather than ported as-is.
/ hard dependencies - imported here as module-local handles (before the impl loads), used by segmentedtp.q
pubsub:use`di.pubsub
eodtime:use`di.eodtime
tplog:use`di.tplog
\l ::segmentedtp.q
/ module version, read from the VERSION file (one plain-text file to bump per release). read
/ module-relative at load (`:::` resolves to di/segmentedtp) and BEFORE export, since export:([...])
/ evaluates each name; version stays in the export so di.depcheck reads it from the export dict.
/ trim, and fail LOUD on a missing/unreadable/empty VERSION, rather than a bare `first read0`:
/ a raw OS error names no module, and an empty or whitespace-padded value is worse than an error -
/ di.depcheck compares versions as STRINGS, so padding silently breaks the comparison and an empty
/ value reads as "exports no version", failing every dependent module's check for a reason that
/ points nowhere near the real cause. same shape as di.rdb, di.dbwrite, di.eodtime and di.tickerplant
version:@[{trim first read0 x};`:::VERSION;{'"di.segmentedtp: VERSION file missing or unreadable"}];
if[0=count version;'"di.segmentedtp: VERSION file is empty"];
export:([init;teardown;upd;tablelist;subdetails;version;getapimeta;readcustomcsv;setcustommode;getcounts])
