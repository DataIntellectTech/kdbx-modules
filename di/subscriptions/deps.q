/ hard module dependencies and their minimum versions, validated by di.depcheck
/ the modularisation plan places di.subscriptions in the FRAMEWORK tier with
/ `-> di.servers, di.pubsub`. both are real module imports, `use`d in init.q:
/   - di.servers: getsubscriptionhandles - the port of TorQ's .sub.getsubscriptionhandles
/     (subscriptions.q:11) - resolves a tickerplant handle by proctype/procname off
/     di.servers.SERVERS, calling only `getservers`
/   - di.pubsub: the LOCAL publisher this process republishes through. a chained or segmented
/     tickerplant subscribes upstream and serves the same tables downstream (TorQ chainedtp.q:71-82
/     and sctp.q:15-25 do exactly this, then publish via .ps.publish and serve their table list from
/     the pubsub registry, chainedtp.q:7). with the republish config key set, subscribe registers
/     the tables it defined at root with di.pubsub so it can extract their schemas and fan out
/ log and handlers stay INJECTED via init as dictionaries of functions - the plan's tier table
/ excludes logging, timer and handler management from the hard dependency tree by design
/ the tp log is replayed with kdb+'s native -11!, not via di.tplog: this module replays the FIRST n
/ messages, and di.tplog.check is built for the replay-everything caller (tickerlogreplay.q,
/ lastmessage 0W). see subscriptions.md for the full reasoning
/ NB the di.pubsub minimum is 0.2.0, not 0.1.0: this module needs BOTH of that release's changes.
/ getsubtables (the handoff reads the current publish set back before adding to it) and the .z.pc
/ CHAINING fix - a 0.1.0 di.pubsub replaces .z.pc at load and would silently destroy this module's
/ own dropped-connection observer, which is the failure the handlers dependency exists to prevent
deps:`di.servers`di.pubsub!("0.1.0";"0.2.0");
