/ dbwrite module - sort, attribute application, save-down manipulation, and GC utilities
/ used by processes that persist data to disk (rdb, wdb, tickerlogreplay)

\l ::dbwrite.q

export:([init;readcsv;sort;applyattr;savedown;appenddown;manipulate;postreplay;gc])