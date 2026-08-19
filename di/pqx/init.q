/ KDB-X Parquet extract module to save kdb+ data to parquet storage convention

arrow:use`kx.arrow

\l ::pqx.q

export:([init;extract;getmanifest;checkandconvertcols;estimate;plan;writefile;tryfn])
