/ di.subscriptions - subscribe a process (e.g. di.torq.proc.rdb) to a tickerplant. In one flow it
/ fetches the schema + log details via the TP's subdetails call, defines the tables locally,
/ replays the pre-subscription log EXACTLY once (via di.tplogmgr.replayupto, using the
/ message counts the TP reported at subscription time), then lets live updates flow through the
/ root `upd`. Ported/simplified from TorQ/code/common/subscriptions.q (.sub).
/ ---
/ Two tickerplant protocols are supported, chosen the way TorQ's own .sub.subscribe chooses
/ (subscriptions.q:92-105): read a root `tptype` off the handle, defaulting to `standard when the
/ variable is undefined.
/   `standard  - di.torq.proc.tickerplant and di.torq.proc.chainedtp. Publish `.u.subdetails,
/                returning `tables`schemas`logfile`rowcount`date - ONE log file, one count.
/   `segmented - di.torq.proc.segmentedtp. Publishes a bare `subdetails, returning
/                `schemalist`logfilelist`rowcounts`date`logdir - MANY log files, one
/                (msgcount;logfile) pair each, because it splits the day's log by design.
/ NB `rowcounts` (segmented) counts ROWS and is NOT a replay bound - -11! is message-limited, and
/ the message counts live inside logfilelist. A closed segment reports the 0W sentinel, which
/ di.tplogmgr.replayupto already treats as "replay the whole file", so it needs no special case.
/ ---
/ Scope (critical path): connect+subscribe+replay for a co-located subscriber (it reads the TP
/ log files directly, same filesystem - the classic tick assumption). Not yet:
/ auto-reconnect/resubscribe, filtered-column subscriptions, remote-log streaming.

/ registry schema - the template init seeds the live registry from. Named apart from the live
/ state so each name has one meaning (bare module-local names and .z.m are the same storage).
registryschema:([]handle:`int$();tabs:();syms:();subtime:`timestamp$());

/ config values arrive as symbols (.q settings) or strings (.toml, command-line overrides), so coerce
/ at the point of use - a string reaching `boolean$ yields a boolean LIST, not an atom
tobool:{[x] $[-1h=type x;x;10h=abs type x;(lower (),x) in ("true";"1";"t";"y";"yes");`boolean$x]};

init:{[config;deps]
  / wire the injected deps, read config and reset the subscription registry
  if[99h<>type config;'"di.subscriptions: config must be a dict"];
  if[not `log in key deps;'"di.subscriptions: log dependency is required - see di.util.log"];
  .z.m.log:deps`log;
  .z.m.tp:use`di.tplogmgr;          / for replayupto (repair-aware, count-limited -11!)
  .z.m.registry:registryschema;
  / a log file that cannot be replayed is logged and SKIPPED by default, so a subscriber comes up with
  / the data it can still get. Set failonreplayerror to make it fatal instead: a consumer whose own
  / state must faithfully mirror the tickerplant's - di.torq.proc.chainedtp raises today for exactly
  / this reason - cannot accept silently incomplete history
  .z.m.failonreplayerror:$[`failonreplayerror in key config;tobool config`failonreplayerror;0b];
  };

raiseerror:{[ctx;msg]
  / internal - log an error under ctx then signal it, so a failure is observable in the log and
  / not only as an exception the caller may swallow
  .z.m.log[`error][ctx;msg];
  '"di.subscriptions: ",string[ctx],": ",msg;
  };

/ which tickerplant is on the other end of this handle? sends a function that reads the root
/ `tptype` ON THE TICKERPLANT, defaulting to `standard where the variable is undefined - exactly
/ TorQ's probe. di.torq.proc.tickerplant and di.torq.proc.chainedtp define none; only
/ di.torq.proc.segmentedtp publishes one.
gettptype:{[tph]
  t:@[tph;({@[value;`tptype;`standard]};`);`];
  if[null t;raiseerror[`subscribe;"could not determine tickerplant type"]];
  t
  };

/ the subscription call itself - the ROOT NAME differs by protocol, so this has to be decided
/ before the call, not after it: a segmented TP has no `.u.subdetails to answer.
callsubdetails:{[tph;tptype;tabs;syms]
  $[tptype=`standard;
    tph(`.u.subdetails;tabs;syms);
    tptype in `chained`segmented;
    tph(`subdetails;tabs;syms);
    raiseerror[`subscribe;"unrecognised tickerplant type: ",string tptype]]
  };

/ tablename!schema dict from whichever protocol answered. segmented returns `schemalist, a list
/ of (table;schema) pairs; standard returns `schemas, already a dict.
getschemas:{[sd]
  $[`schemalist in key sd;
    (sd[`schemalist][;0])!sd[`schemalist][;1];
    sd`schemas]
  };

/ the (msgcount;logfile) pairs to replay, normalised to the segmented shape. A standard TP's
/ single logfile/rowcount becomes a one-element list, so one loop serves both - as TorQ's own
/ standard branch does (it builds enlist(.u`i`L)).
getlogpairs:{[sd]
  if[`logfilelist in key sd; :sd`logfilelist];
  / nothing logged yet, or logging disabled on the TP (tplogdir unset -> rowcount stays 0 and logfile
  / is `): there is no history to replay and that is not an error. A missing log file is only a fault
  / when the TP claims it logged something
  if[0=sd`rowcount; :()];
  lf:sd`logfile;
  if[null lf;
    raiseerror[`replay;"TP reports ",(string sd`rowcount)," logged message(s) but no log file - cannot replay"]];
  enlist(sd`rowcount;lf)
  };

/ filtering replay wrapper installed as root `upd` during log replay: forward only rows
/ for subscribed tables/syms to the real upd. Live data is already TP-filtered; only the
/ log needs filtering to match a narrowed subscription. For a segmented TP this matters even
/ more - each physical file holds the messages of EVERY table written to it, including tables
/ outside this request, so the filter has to span the whole replay.
/ x is the stamped payload: time first, sym second - either one column per field, or one ATOM per
/ field. The atom form is not hypothetical: di.torq.proc.tickerplant's stamp[] deliberately keeps an
/ atom row atomic and LOGS it that way, enlisting only on the publish path. Indexing an atom row's
/ sym gives an atom, and `where` on an atom throws 'type - which runreplay would catch and report as
/ a skipped file, losing the whole log silently. Normalise to columns before filtering.
ascols:{[d] $[0>type first d;enlist each d;d]};

replayfilter:{[origupd;tabs;syms;t;x]
  if[not $[tabs~`;1b;t in tabs]; :()];        / skip tables we didn't subscribe to
  if[not syms~`;
    x:ascols x;
    x:x@\:where x[1] in syms];                / keep only subscribed syms (col 1)
  origupd[t;x];
  };

/ protected count-limited replay through root `upd`; returns the count, or (`replayerr;e).
runreplay:{[lf;n] .[{[m;lf;n](m`replayupto)[lf;n]};(.z.m.tp;lf;n);{[e](`replayerr;e)}]};

/ one physical log file. By default a file that fails to replay is logged and SKIPPED, not fatal: the
/ subscriber comes up with a real (possibly partial) dataset and a log entry naming the bad file,
/ rather than refusing to subscribe because one older segment is corrupt. This is TorQ's own
/ policy - .sub.replay wraps each file in its own protected block and continues the loop.
/ failonreplayerror flips it to fail-fast for a consumer that cannot accept partial history.
replayone:{[pair]
  r:runreplay[pair 1;pair 0];
  if[-7h<>type r;
    if[.z.m.failonreplayerror;
      raiseerror[`replay;"replay failed for ",(string pair 1),": ",last r]];
    .z.m.log[`error][`subscriptions;"replay failed for ",(string pair 1),": ",last r];
    :0];
  .z.m.log[`info][`subscriptions;"replayed ",(string r)," message(s) from ",string pair 1];
  r
  };

/ every file in order; returns the total replayed. NB the count guard is load-bearing: `sum ()` is `()`,
/ not 0, so an empty pair list (a segmented TP with nothing logged for the requested tables) would
/ otherwise return a generic list and fail the -7h type check downstream
replayall:{[pairs] $[count pairs;sum replayone each pairs;0]};

/ replay the pre-subscription history, filtered to the subscribed tables/syms. NB module-namespace
/ boundary: a `use`-loaded module cannot create/populate ROOT tables via bare symbols (they land in
/ the module's private namespace) - so table creation uses @[`.;name;:;..] and replay drives the
/ ROOT `upd` (which di.torq.proc.rdb sets to `insert` at root). For the common all/all subscription
/ we don't wrap upd at all; for a narrowed subscription we install a root-level filter wrapper ONCE
/ around the whole loop and restore the original after, success or failure.
doreplay:{[pairs;tabs;syms;alltabs]
  if[(tabs~`) and syms~`; :replayall pairs];
  origupd:$[`upd in key `.;`. `upd;{[t;x]}];
  @[`.;`upd;:;replayfilter[origupd;$[tabs~`;alltabs;(),tabs];syms]];
  n:.[replayall;enlist pairs;{[e](`replayerr;e)}];
  @[`.;`upd;:;origupd];                                / restore, success or failure
  if[-7h<>type n;raiseerror[`replay;"replay failed: ",last n]];
  n
  };

/ the dict subscribe returns. A standard TP's own dict is passed through, so existing consumers
/ (di.torq.proc.rdb, wdb, chainedtp - which asserts the classic key set with `in`, so extra keys are
/ fine) are unaffected. A segmented TP's dict is normalised to carry the same
/ `tables`schemas`rowcount`date those consumers read, plus its own extra keys. No `logfile` key is
/ synthesised: its absence is the honest signal that `logfilelist` is authoritative.
/ ---
/ `rowcount` keeps its protocol-native meaning - the count the TP REPORTED for a standard TP, the
/ replayed total for a segmented one, where no comparable reported total exists (closed segments
/ report the 0W sentinel, so summing them is meaningless).
/ `replayed` is added for BOTH and is always the number of messages that actually made it through
/ root `upd`. Without it a caller cannot distinguish a clean replay from one where every file was
/ skipped: the default policy logs and continues, so a standard TP's dict would still report the
/ TP's claim while nothing at all had landed, and di.torq.proc.rdb would log that claim as fact.
normalisedetails:{[sd;schemas;replayed]
  if[not `logfilelist in key sd; :sd,(enlist`replayed)!enlist replayed];
  `tables`schemas`rowcount`date`logfilelist`logdir`rowcounts`replayed!
    (key schemas;schemas;replayed;sd`date;sd`logfilelist;sd`logdir;sd`rowcounts;replayed)
  };

/ subscribe over an already-open tickerplant handle `tph` (di.torq.proc.rdb obtains it via
/ di.torq.servers). tabs/syms: ` for all, else a list. replay: 1b to replay the tp log.
/ Returns the subscription-details dict (tables/schemas/rowcount/date, plus logfile for a
/ standard TP or logfilelist/logdir/rowcounts for a segmented one).
subscribe:{[tph;tabs;syms;replay]
  tptype:gettptype tph;
  sd:callsubdetails[tph;tptype;tabs;syms];
  schemas:getschemas sd;
  / define the subscribed tables at ROOT from the returned schemas (they carry g# etc.).
  / @[`.;name;:;schema] targets root explicitly - a bare `name set schema` from inside
  / this module would create the table in the module's private namespace instead.
  {@[`.;x;:;y]}'[key schemas;value schemas];
  n:$[replay;doreplay[getlogpairs sd;tabs;syms;key schemas];0];
  .z.m.registry:.z.m.registry,([]handle:enlist tph;tabs:enlist key schemas;syms:enlist syms;subtime:enlist .z.p);
  .z.m.log[`info][`subscriptions;
    "subscribed to ",(", " sv string key schemas)," on ",(string tptype)," tickerplant handle ",string tph];
  normalisedetails[sd;schemas;n]
  };

/ are we currently subscribed to anything? (di.torq.proc.rdb's connectivity check)
subscribed:{[] 0<count .z.m.registry};

/ the active-subscriptions registry (introspection)
getsubscriptions:{[] .z.m.registry};

getapimeta:{[]
  / callable api for di.torq to register with di.api. init/getapimeta/version are plumbing di.torq
  / calls by convention and are deliberately omitted. one (name;public;descrip;params;return) row
  / per line - flip cols!flip rows.
  :flip `name`public`descrip`params`return!flip(
    (`subscribe;       1b; "subscribe over an open tickerplant handle and replay its log exactly once";
       "[int: tickerplant handle; symbol(list): tables (` for all); symbol(list): syms (` for all); boolean: replay]";
       "dict: tables, schemas, rowcount, date and the log details for the tickerplant's protocol");
    (`subscribed;      1b; "is any subscription currently recorded?";
       "[]";                                                       "boolean: 1b if the registry is non-empty");
    (`getsubscriptions;1b; "the active-subscriptions registry";
       "[]";                                                       "table: handle, tabs, syms and subtime"));
  };
