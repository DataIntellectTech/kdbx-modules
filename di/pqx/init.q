/ KDB-X Parquet extract module to save kdb+ data to parquet storage convention

arrow:use`kx.arrow
pq:use`kx.pq
pqt:use`kx.pq.t

\l ::pqx.q

/ set version string from VERSION file - fail is missing or empty
version:@[{trim first read0 x};`:::VERSION;{'"di.pqx: VERSION file missing or unreadable"}];
if[0=count version;'"di.pqx: VERSION file is empty"];

export:([init;extract;getmanifest;getdefault;checkandconvertcols;estimate;plan;writefile;readfile;tryfn;buildvirtualtable;checkvirtuallevels;checkvirtualtypes;version])
