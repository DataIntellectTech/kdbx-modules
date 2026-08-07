/ hard module dependencies and their minimum versions, validated by di.depcheck
/ di.subscriptions has NO hard dependencies:
/   - log and handlers are injected via init as dictionaries of functions. handlers is required for
/     the .z.pc observer that marks a dropped connection's subscriptions dead: .z.W alone cannot do
/     it, because kdb+ recycles handle numbers and a reused number revives a stale row
/   - handle resolution is the CALLER's job (di.rdb/di.wdb obtain a tickerplant handle from
/     di.servers.gethandlebytype and pass it in), so there is no di.servers edge - the plan's
/     dependency tree lists one, but every caller already imports di.servers directly and a
/     getsubscriptionhandles wrapper here would only duplicate it
/   - di.pubsub is the PUBLISHER side (TorQ's .stpps - the tickerplant's own subscriber registry).
/     a subscribing process never calls it; legacy .sub never referenced it either. the plan's
/     tree lists it for this module in error
/   - the tp log is replayed with kdb+'s native -11!, not via di.tplog: this module replays the
/     FIRST n messages, and di.tplog.check is built for the replay-everything caller
/     (tickerlogreplay.q, lastmessage 0W). see subscriptions.md for the full reasoning
deps:(`$())!();
