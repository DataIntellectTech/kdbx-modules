/ publisher/subscriber management - the tickerplant side of a subscription: a registry of who wants
/ which tables (optionally sym- or condition-filtered), and the fan-out that publishes to them

\l ::pubsub.q

/ module version, read from the VERSION file rather than hardcoded, so a release bump touches one
/ plain-text file. read module-relative at load (`:::` resolves to di/pubsub) and BEFORE the export
/ line, since export:([...]) evaluates each name. NB `version` must STAY in the export: di.depcheck
/ resolves a dependency's minimum version from the export dict, and reports "exports no version" -
/ failing the dependency check - for any module that omits it
version:first read0`:::VERSION

export:([subscribe;subscribestr;subscribestrfilter;publish;setsubtables;getsubtables;callendofperiod;callendofday;closesub;pubclear;init;version])
