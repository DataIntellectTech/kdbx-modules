/ di.tplog - tickerplant log lifecycle (open/write/roll/replay/replayupto/logname) plus corruption
/ check/repair. self-contained (no hard `use` deps); log is injected via init. see tplog.md
\l ::tplog.q

/ module version, read from the VERSION file before the export line evaluates each name.
/ trim so a trailing newline / CRLF cannot pad the semver di.depcheck compares
version:trim first read0`:::VERSION

export:([init;logname;open;write;roll;replay;replayupto;check;repair;getapimeta;version])
