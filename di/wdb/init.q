/ di.wdb - the write database. subscribes to a tickerplant, periodically flushes in-memory tables to
/ a working directory partitioned by date, and at end of day sorts that data, moves it into the hdb
/ and triggers rdb/hdb reloads.
/ ported from TorQ's code/processes/wdb.q, plus the process-code files code/wdb/origstartup.q and
/ code/wdb/writedown.q, the .save section of code/common/dbwriteutils.q, and defaults from
/ config/settings/wdb.q. see wdb.md for scope, divergences and design rationale.

/ hard dependencies, per the modularisation plan's PROCESS tier. imported at module LOAD, before the
/ implementation is loaded - the shape di.rdb, di.subscriptions and di.eodtime use. a QPATH missing
/ any of these fails here, loudly, rather than at the first call. see deps.q for what this module
/ actually calls through each edge.
/ NB module handles must be reached by dot-sugar off a TOP-LEVEL name like these. a `use` inside a
/ function binds a function-local name, and the dotted accessor then throws (`'servers.getservers`)
servers:use`di.servers
subscriptions:use`di.subscriptions
dbwrite:use`di.dbwrite
/ NB named osutil, not os: `os is a real q error (operating system error), and qlint's VAR_Q_ERROR
/ flags the collision. this module does a lot of filesystem work that can legitimately throw 'os,
/ so a bare `os` handle would make a failed mv or deldir ambiguous with a name resolution failure
osutil:use`di.os
/ NB di.merge is imported but NOT called anywhere in this version, deliberately. every .merge.*
/ call in the legacy source is gated on `writedownmode in partwritemodes`, which is false for
/ `default - the only writedown mode this version accepts. it is declared here and in deps.q so
/ parted-mode support is an additive change later rather than a re-scope; an unreached import
/ costs nothing at runtime. see wdb.md, Scope
merge:use`di.merge

\l ::wdb.q

/ module version, read from the VERSION file rather than hardcoded, so a release bump touches one
/ plain-text file. read module-relative at load (`:::` resolves to di/wdb) and BEFORE the export
/ line, since export:([...]) evaluates each name.
/ NB `version` must STAY in the export: di.depcheck resolves a dependency's minimum version from the
/ export dict (checkdepversion) and classes a missing one as a FAILURE, which makes di.depcheck.init
/ throw for any process loading a module that declares this one as a hard dependency.
/ trim, and fail LOUD on a missing/unreadable/empty VERSION rather than a bare `first read0`: a raw
/ OS error names no module, and read0 strips the line terminator but not trailing spaces - depcheck
/ compares versions as STRINGS, so a padded value silently fails every dependent module's check
version:@[{trim first read0 x};`:::VERSION;{'"di.wdb: VERSION file missing or unreadable"}];
if[0=count version;'"di.wdb: VERSION file is empty"];

/ NB export:([...]) EVALUATES each name, so it can only list names that already exist - the export
/ list and the implementation cannot drift apart in this direction.
/ NB the five module handles above are deliberately NOT exported - they are this module's imports,
/ not part of its api.
/ init and getapimeta are framework plumbing di.torq calls by convention; every other name here has
/ a getapimeta row, which the test suite asserts
export:([init;start;teardown;version;getapimeta;
         endofday;endofperiod;status])
