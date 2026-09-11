/ dbwrite module - write, sort, and attribute utilities for on-disk data
/ used by processes that persist data to disk (rdb, wdb, tickerlogreplay)

\l ::dbwrite.q

/ module version, read from the on-disk VERSION file (the module-local `:::` path convention).
/ di.torq.proc.rdb's and di.torq.proc.wdb's deps.toml both declare di.dbwrite, so di.torq.depcheck needs
/ BOTH the file (pre-load manifest walk) and this export (post-load session audit).
version:first read0`:::VERSION

export:([init;readcsv;setconfig;getconfig;sort;applyattr;savedown;appenddown;version])
