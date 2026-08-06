/ dbwrite module - write, sort, and attribute utilities for on-disk data
/ used by processes that persist data to disk (rdb, wdb, tickerlogreplay)

\l ::dbwrite.q

export:([init;readcsv;setconfig;getconfig;sort;applyattr;savedown;appenddown])
