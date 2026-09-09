/ di.torq.handlers - central registry for KDB-X .z.* connection-lifecycle callbacks

\l ::handlers.q

version:first read0`:::VERSION

export:([init;register;remove;list;version])
