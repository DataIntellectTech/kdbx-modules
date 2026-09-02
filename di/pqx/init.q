/ KDB-X Parquet extract module to save kdb+ data to parquet storage convention

arrow:use`kx.arrow
pq:use`kx.pq
pqt:use`kx.pq.t

\l ::pqx.q

/ module version, read from the VERSION file (one plain-text file to bump per release). read
/ module-relative at load (`:::` resolves to di/pqx) and BEFORE export, since export:([...])
/ evaluates each name; version stays in the export so di.depcheck reads it from the export dict.
/ trim, and fail LOUD on a missing/unreadable/empty VERSION, rather than a bare `first read0`:
/ a raw OS error names no module, and an empty or whitespace-padded value is worse than an error -
/ di.depcheck compares versions as STRINGS, so padding silently breaks the comparison and an empty
/ value reads as "exports no version", failing every dependent module's check for a reason that
/ points nowhere near the real cause.
version:@[{trim first read0 x};`:::VERSION;{'"di.pqx: VERSION file missing or unreadable"}];
if[0=count version;'"di.pqx: VERSION file is empty"];

export:([init;extract;getmanifest;checkandconvertcols;estimate;plan;writefile;readfile;tryfn;buildvirtualtable;castvirtualcol;version])
