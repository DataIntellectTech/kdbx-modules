/ di.clienttracking - track connected client sessions via di.handlers connection-lifecycle events
\l ::clienttracking.q
/ module version, read from the VERSION file (one plain-text file to bump per release). read
/ module-relative at load (`:::` resolves to di/clienttracking) and BEFORE export, since export:([...])
/ evaluates each name; version stays in the export so di.depcheck reads it from the export dict
version:trim first read0`:::VERSION
export:([init;getclients;addclient;cleanup;enableusage;getapimeta;version])
