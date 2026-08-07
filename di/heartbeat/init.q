/ di.heartbeat - periodic liveness signalling over pub/sub, and monitoring of other processes' beats
/ consolidates TorQ's heartbeat.q (.hb), covering both the publisher and the monitor role

\l ::heartbeat.q

/ module version, read from the VERSION file rather than hardcoded, so a release bump touches one
/ plain-text file. NB `version` STAYS in the export: di.depcheck resolves a dependency's version from
/ the export dict and fails the check with "exports no version" for any module that drops it
version:first read0`:::VERSION

/ public api - init and getapimeta are framework plumbing di.torq calls by convention; every other
/ name here carries a getapimeta row, which the test suite asserts
export:([init;teardown;version;getapimeta;
         publishheartbeat;checkheartbeat;storeheartbeat;
         addprocs;removeprocs;subscribe;gethb;getownhb;setcp])
