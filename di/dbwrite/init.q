/ dbwrite module - sort, attribute application, save-down manipulation, and GC utilities
/ used by processes that persist data to disk (rdb, wdb, tickerlogreplay)

\l ::dbwrite.q

/ default sort config file - set directly or extend init with a config dep
defaultfile:`;

export:([init;sort;applyattr;loadconfig;manipulate;postreplay;gc])