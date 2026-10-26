/ write, sort and attribute utilities for on-disk data

\l ::dbwrite.q

/ module version from the VERSION file, checked by di.torq.depcheck
version:first read0`:::VERSION

export:([init;readcsv;setconfig;getconfig;sort;applyattr;savedown;appenddown;manipulate;postreplay;gc;version])
