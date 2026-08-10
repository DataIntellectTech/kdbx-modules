\l ::pubsub.q

/ module version, read from the on-disk VERSION file (the module-local `:::` path convention).
/ di.proc.tickerplant's deps.toml declares di.pubsub, so di.torq.depcheck needs BOTH the file
/ (pre-load manifest walk) and this export (post-load session audit).
version:first read0`:::VERSION

export:([subscribe;subscribestr;subscribestrfilter;publish;setsubtables;callendofperiod;callendofday;closesub;pubclear;init;version])
