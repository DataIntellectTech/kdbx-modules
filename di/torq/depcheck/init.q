/ di.torq.depcheck - dependency presence/version, core-contract, and .z.ts ownership auditing for kdb-x modules
/ intended to run once, post-load, after a host process (di.torq) has `use`d every module it needs - see depcheck.md

\l ::depcheck.q

version:first read0`:::VERSION

export:([init;version;checkcontract;checkversiongraph;checkversiongraphfile])
