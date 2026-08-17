/ di.rdb - the real-time database. subscribes to a tickerplant, replays the day's tickerplant log to
/ recover intraday state, accumulates live updates in memory, and at end of day writes each table down
/ to the hdb, clears it and tells the hdb(s) to reload.
/ ported from TorQ's code/processes/rdb.q, plus the process-code files code/rdb/rdbstandard.q and
/ code/rdb/endofperiod.q, with defaults from config/settings/rdb.q. see rdb.md.

/ hard dependencies, per the modularisation plan's PROCESS tier. imported at module LOAD, before the
/ implementation is loaded - the shape di.subscriptions, di.permissions and di.eodtime use. a QPATH
/ missing any of these fails here, loudly, rather than at the first call. see deps.q for what this
/ module actually calls through each edge.
/ NB module handles must be reached by dot-sugar off a TOP-LEVEL name like these. a `use` inside a
/ function binds a function-local name, and the dotted accessor then throws (`'servers.getservers`)
servers:use`di.servers
subscriptions:use`di.subscriptions
dbwrite:use`di.dbwrite
eodtime:use`di.eodtime
asyncutil:use`di.asyncutil

\l ::rdb.q

/ module version, read from the VERSION file rather than hardcoded, so a release bump touches one
/ plain-text file. read module-relative at load (`:::` resolves to di/rdb) and BEFORE the export line,
/ since export:([...]) evaluates each name.
/ NB `version` must STAY in the export: di.depcheck resolves a dependency's minimum version from the
/ export dict (checkdepversion) and reports "exports no version" - failing the check - for any module
/ that omits it
version:first read0`:::VERSION

/ NB export:([...]) EVALUATES each name, so it can only list names that already exist - the export list
/ and the implementation cannot drift apart in this direction.
/ NB the five module handles above are deliberately NOT exported - they are this module's imports, not
/ part of its api.
/ init and getapimeta are framework plumbing di.torq calls by convention; every other name here has a
/ getapimeta row, which the test suite asserts
export:([init;teardown;start;version;getapimeta;
         endofday;reload;endofperiod;
         getpartition;moveandclear;status])
