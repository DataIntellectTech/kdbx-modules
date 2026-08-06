// structured logger - default log dependency for di.* modules
\l ::log.q

// module version, read from the on-disk VERSION file (the module-local `:::` path convention).
// di.torq.depcheck reads the file for its pre-load manifest walk and this export for its
// post-load session audit. Safe to export here: this module has no getapimeta contract test
// asserting an exact export set (unlike di.util.toml / di.torq.config).
version:first read0`:::VERSION

export:([createlog;logdict;trace;debug;info;warn;error;fatal;version])
