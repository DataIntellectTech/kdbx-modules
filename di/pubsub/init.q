/ publisher/subscriber management - the tickerplant side of a subscription: a registry of who wants
/ which tables (optionally sym- or condition-filtered), and the fan-out that publishes to them

\l ::pubsub.q

/ version string, read from the VERSION file - fails if missing or empty
/ NB must stay in export: di.depcheck reads it from here to resolve a dependency's minimum version
version:first read0`:::VERSION

export:([subscribe;subscribestr;subscribestrfilter;publish;setsubtables;getsubtables;callendofperiod;callendofday;closesub;pubclear;init;version])
