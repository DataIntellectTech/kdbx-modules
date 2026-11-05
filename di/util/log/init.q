// structured logger - default log dependency for di.* modules
\l ::log.q

// module version from the VERSION file, checked by di.torq.depcheck
version:first read0`:::VERSION

export:([createlog;logdict;trace;debug;info;warn;error;fatal;version])
