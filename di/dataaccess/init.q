/ time-sharded query layer over the gateway: getdata/getdatafull (typed) and execquery (query string)

\l ::dataaccess.q

version:first read0`:::VERSION

export:([init;getdata;getdatafull;execquery;setpartitions;
  shardresult;sharderror;removerequests;version])
