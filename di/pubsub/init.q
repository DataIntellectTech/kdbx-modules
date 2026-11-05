\l ::pubsub.q

/ module version from the VERSION file, checked by di.torq.depcheck
version:first read0`:::VERSION

export:([subscribe;subscribestr;subscribestrfilter;publish;setsubtables;callendofperiod;callendofday;closesub;pubclear;init;version])
