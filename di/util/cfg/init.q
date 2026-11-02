/ config resolution helpers - path roots and value coercion
\l ::cfg.q

/ module version from the VERSION file, checked by di.torq.depcheck
version:first read0`:::VERSION

export:([apphome;datahome;resolvedir;asbool;aslong;totimespan;tosym;aslist;assym;astoklist;version])
