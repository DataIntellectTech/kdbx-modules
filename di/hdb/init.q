/ di.hdb - the historical database process type. mounts a partitioned database directory and exposes a
/ remotely-triggerable reload, so a process that has just persisted a new partition can make this one
/ pick it up without a restart.
/ ported from TorQ's code/hdb/hdbstandard.q, with the process defaults from config/settings/hdb.q.
/ see hdb.md.

/ NO hard dependencies. the modularisation plan's tier table lists `di.hdb -> di.sort`; that edge does
/ not exist - see deps.q for the evidence. log is injected via init; nothing else is needed.
\l ::hdb.q

/ module version, read from the VERSION file rather than hardcoded, so a release bump touches one
/ plain-text file. read module-relative at load (`:::` resolves to di/hdb) and BEFORE the export line,
/ since export:([...]) evaluates each name.
/ NB `version` must STAY in the export: di.depcheck resolves a dependency's minimum version from the
/ export dict (checkdepversion) and reports "exports no version" - failing the check - for any module
/ that omits it.
/ trim, and fail LOUD on a missing/unreadable/empty VERSION rather than using a bare `first read0`:
/ a raw OS error names no module, and an empty or whitespace-padded value is worse than an error -
/ di.depcheck compares versions as strings, so padding silently breaks the comparison and an empty
/ value reads as "exports no version". this is the shape di.rdb, di.dbwrite and di.eodtime use
version:@[{trim first read0 x};`:::VERSION;{'"di.hdb: VERSION file missing or unreadable"}];
if[0=count version;'"di.hdb: VERSION file is empty"];

/ NB export:([...]) EVALUATES each name, so it can only list names that already exist - the export
/ list and the implementation cannot drift apart in this direction.
/ init, getapimeta and version are framework plumbing di.torq calls by convention; the
/ remaining names each have a getapimeta row, which the test suite asserts
export:([init;teardown;start;version;getapimeta;reload;getattributes;status])
