/ di.dataaccess - data access / query normalisation layer over the gateway.
/ Two entry points over one shared routing + scatter/gather + request-lifecycle core:
/   getdata / getdatafull - typed, date-normalising, map-reducing (TorqX)
/   execquery             - arbitrary query STRING, time-sharded, caller-supplied joinfn (kdbx)
/ See docs/reconciliation/dataaccess.md for the merge rationale.

\l ::dataaccess.q

version:first read0`:::VERSION

export:([init;getdata;getdatafull;execquery;setpartitions;
  shardresult;sharderror;removerequests;version])
