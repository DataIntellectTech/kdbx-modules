/ KDB-X Parquet extract module to save kdb+ data to parquet storage convention

arrow:use`kx.arrow
pq:use`kx.pq
pqt:use`kx.pq.t

\l ::pqx.q

export:([init;extract;getmanifest;checkandconvertcols;estimate;plan;writefile;readfile;tryfn;buildvirtualtable;castvirtualcol])
