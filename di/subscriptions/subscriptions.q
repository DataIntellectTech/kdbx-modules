/ di.subscriptions - subscribe a process (e.g. di.proc.rdb) to a tickerplant. In one flow it
/ fetches the schema + log details via the TP's .u.subdetails, defines the tables locally,
/ replays the pre-subscription log EXACTLY once (via di.tplogmgr.replayupto, using the
/ rowcount the TP reported at subscription time), then lets live updates flow through the
/ root `upd`. Ported/simplified from TorQ/code/common/subscriptions.q (.sub), written
/ against di.proc.tickerplant's clean single-call subdetails protocol rather than the classic
/ standard-TP .u.i/.u.L/.u.d global reads.
/ ---
/ Scope (v1, critical path): connect+subscribe+replay for a co-located subscriber (it
/ reads the TP log file directly, same filesystem - the classic tick assumption). Not yet:
/ auto-reconnect/resubscribe, filtered-column subscriptions, remote-log streaming.

/ registry of active subscriptions - for health checks now, reconnect later.
SUBSCRIPTIONS:([]handle:`int$();tabs:();syms:();subtime:`timestamp$())

init:{[config;deps]
  if[not `log in key deps;'"di.subscriptions: log dependency is required - see di.util.log"];
  .z.m.log:deps`log;
  .z.m.tp:use`di.tplogmgr;          / for replayupto (repair-aware, count-limited -11!)
  }

/ filtering replay wrapper installed as root `upd` during log replay: forward only rows
/ for subscribed tables/syms to the real upd. Live data is already TP-filtered; only the
/ log (which holds every table/sym) needs filtering to match a narrowed subscription.
/ x is the stamped payload: a list of columns with time first, sym second.
replayfilter:{[origupd;tabs;syms;t;x]
  if[not $[tabs~`;1b;t in tabs]; :()];        / skip tables we didn't subscribe to
  if[not syms~`; x:x@\:where x[1] in syms];   / keep only subscribed syms (col 1)
  origupd[t;x];
  }

/ protected count-limited replay through root `upd`; returns the count, or (`replayerr;e).
runreplay:{[lf;n] .[{[m;lf;n](m`replayupto)[lf;n]};(.z.m.tp;lf;n);{[e](`replayerr;e)}]}

/ replay the pre-subscription history for a subscription-details dict `sd`, filtered to
/ the subscribed tables/syms. NB module-namespace boundary: a `use`-loaded module cannot
/ create/populate ROOT tables via bare symbols (they land in the module's private
/ namespace) - so table creation uses @[`.;name;:;..] and replay drives the ROOT `upd`
/ (which di.proc.rdb sets to `insert` at root). For the common all/all subscription we don't
/ wrap upd at all; for a narrowed subscription we temporarily install a root-level filter
/ wrapper (built from replayfilter) and restore the original after.
doreplay:{[sd;tabs;syms]
  lf:sd`logfile;
  if[null lf;'"di.subscriptions: TP reports rowcount>0 but no log file - cannot replay"];
  r:$[(tabs~`) and syms~`;
      runreplay[lf;sd`rowcount];                          / all/all: root upd handles it
      [origupd:$[`upd in key `.;`. `upd;{[t;x]}];          / narrowed: wrap root upd
       @[`.;`upd;:;replayfilter[origupd;$[tabs~`;sd`tables;(),tabs];syms]];
       rr:runreplay[lf;sd`rowcount];
       @[`.;`upd;:;origupd];                               / restore, success or failure
       rr]
      ];
  $[-7h=type r;
    .z.m.log[`info][`subscriptions;"replayed ",(string sd`rowcount)," message(s) from ",string lf];
    .z.m.log[`error][`subscriptions;"replay failed for ",(string lf),": ",last r]];
  }

/ subscribe over an already-open tickerplant handle `tph` (di.proc.rdb obtains it via
/ di.torq.servers). tabs/syms: ` for all, else a list. replay: 1b to replay the tp log.
/ Returns the subscription-details dict (tables/schemas/logfile/rowcount/date).
subscribe:{[tph;tabs;syms;replay]
  sd:tph(`.u.subdetails;tabs;syms);
  / define the subscribed tables at ROOT from the returned schemas (they carry g# etc.).
  / @[`.;name;:;schema] targets root explicitly - a bare `name set schema` from inside
  / this module would create the table in the module's private namespace instead.
  {@[`.;x;:;y]}'[key sd`schemas;value sd`schemas];
  if[replay and 0<sd`rowcount; doreplay[sd;tabs;syms]];
  .z.m.SUBSCRIPTIONS:.z.m.SUBSCRIPTIONS,([]handle:enlist tph;tabs:enlist sd`tables;syms:enlist syms;subtime:enlist .z.p);
  .z.m.log[`info][`subscriptions;"subscribed to ",(", " sv string sd`tables)," on tickerplant handle ",string tph];
  sd
  }

/ are we currently subscribed to anything? (di.proc.rdb's connectivity check)
subscribed:{[] 0<count .z.m.SUBSCRIPTIONS}

/ the active-subscriptions registry (introspection)
getsubscriptions:{[] .z.m.SUBSCRIPTIONS}
