/ dependency, version, contract and .z.ts ownership auditing for loaded kdb-x modules

\l ::depcheck.q

version:first read0`:::VERSION

export:([init;version;checkcontract;checkversiongraph;checkversiongraphfile])
