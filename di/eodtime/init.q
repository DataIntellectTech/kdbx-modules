/ end-of-day time management - date resolution, roll scheduling and data timestamp adjustment

tz:use`di.tz

\l ::eodtime.q

/ module version, read from the on-disk VERSION file (the module-local `:::` path convention).
/ di.proc.tickerplant's deps.toml declares di.eodtime, so di.torq.depcheck needs BOTH the file
/ (pre-load manifest walk) and this export (post-load session audit of a loaded, declared peer).
version:first read0`:::VERSION

export:([init;getd;getnextroll;getdailyadj;getroll;getdailyadjustment;setnextroll;setdailyadj;setd;version])
