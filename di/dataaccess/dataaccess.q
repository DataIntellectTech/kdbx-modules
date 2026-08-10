/ di.dataaccess - data access / query normalisation layer over the gateway. Accepts a
/ structured, time-ranged request, ROUTES it across time-partitioned backends (one shard per
/ reachable servertype, clipped to its coverage), BUILDS a per-backend FUNCTIONAL-qSQL query
/ (normalising the date column - native `date` on the hdb, derived `date$time` on the rdb),
/ SCATTERS the shards via di.asyncdispatch, then GATHERS and MAP-REDUCES the results back to
/ the client. This is the "generic getdata that handles the rdb-has-no-date-column problem".
/ ---
/ MERGE of two implementations (see docs/reconciliation/dataaccess.md). The structure - routing,
/ scatter/gather/reduce, requests/shardresults bookkeeping, the postback/timeout/deferred-sync
/ request lifecycle - is kdbx-modules feature-dataaccess's, kept. On top of it:
/   (1) queries are also built FUNCTIONALLY (?[t;wc;b;a]) rather than only by string rewriting -
/       robust, and the seam for per-backend date normalisation;
/   (2) dispatch goes through di.asyncdispatch.execqueryto LOCAL mode (replyto 0Ni + a
/       root-published .dataaccess.shardresult postback) - the branch used execquery and hit the
/       ".z.w replies to the client, not to dataaccess" bug its own .md flagged as unfixable from
/       its side; execqueryto (added to asyncdispatch since) is that fix;
/   (3) real map-reduce (a shard-fn then a reduce-fn recombined on the by-keys, with a component
/       split for avg/wavg/vwap) rather than a bare user raze that double-counts grouped aggs.
/ Both entry points are kept and share the whole core:
/   getdata / getdatafull - typed, date-normalising, map-reducing
/   execquery             - arbitrary query STRING, time-sharded, caller-supplied joinfn
/ ---
/ Hard deps (use): di.asyncdispatch (dispatch), di.serverselect (which servertypes are live) -
/ SHARED (idempotent use) with di.proc.gateway, so it reuses the gateway's registered servers +
/ callbacks. Injected via init: log, timer (required) + optional config.
/ Scope: count/sum/min/max/avg + wavg/vwap aggs (avg & the weighted pair map-reduce correctly via a
/ component split - see aggspecs); `date` + plain by-columns; a single time-range filter. Coverage is
/ refreshed at EOD via setpartitions (the gateway calls it at reloadend). Deferred: arbitrary where
/ filters, ordering/sublist, typed input validation (TorQ checkinputs), attribute routing.

asyncdispatch:use`di.asyncdispatch;
serverselect:use`di.serverselect;

errorprefix:"error: ";

/ default coverage: one hdb over all time; override via init `partitions
defaultpartitions:([]servertype:enlist`hdb;coverfrom:enlist -0Wp;coverto:enlist 0Wp);

/ agg fn -> (COMPONENTS; REDUCEFN). The map-reduce split: an aggregate that can't be recombined
/ from its own shard-level value (avg, wavg/vwap) is decomposed into COMPONENTS that CAN - each a
/ hidden per-shard aggregate column - and a REDUCEFN that recombines those components (regrouped
/ on the by-keys) into the final value. count/sum/min/max are single-component (the output col
/ itself); avg = sum + non-null-count, recombined as (sum sums)%(sum counts); wavg/vwap = sum(w*c)
/ + sum(w), recombined as (sum nums)%(sum dens). All exprs are functional-qSQL parse trees, so a
/ bare column symbol is a column reference.
/   COMPONENTS : list of (suffix; shardbuilder[incol]->parsetree). suffix ` = the output col
/                itself (single-component, back-compatible); else the hidden col is <out>__<suffix>.
/   REDUCEFN   : compnames -> parsetree combining the (already-grouped) component columns.
/ NB avg's denominator is sum(not null c) to match q's null-ignoring avg; count (the standalone
/ agg) still counts rows. wavg/vwap follow the sum(w*c)%sum(w) definition (nulls drop consistently).
compname:{[o;suffix] $[suffix~`;o;`$string[o],"__",string suffix]};
aggspecs:()!();
aggspecs[`count]:(enlist(`;{[c] (count;c)});                            {[cn] (sum;cn 0)});
aggspecs[`sum]:  (enlist(`;{[c] (sum;c)});                              {[cn] (sum;cn 0)});
aggspecs[`min]:  (enlist(`;{[c] (min;c)});                              {[cn] (min;cn 0)});
aggspecs[`max]:  (enlist(`;{[c] (max;c)});                              {[cn] (max;cn 0)});
aggspecs[`avg]:  (((`s;{[c] (sum;c)});(`n;{[c] (sum;(not;(null;c)))})); {[cn] ((%);(sum;cn 0);(sum;cn 1))});
aggspecs[`wavg]: (((`n;{[c] (sum;(*;c 0;c 1))});(`d;{[c] (sum;c 0)}));  {[cn] ((%);(sum;cn 0);(sum;cn 1))});
aggspecs[`vwap]: aggspecs`wavg;

/ one row per in-flight request. `mode selects how checkresults recombines the shard results:
/   `getdata   - structured map-reduce over `by/`aggs (this module's typed entry point)
/   `execquery - apply the caller's `joinfn across the raw shard results (the string entry point)
/ so `by`aggs are meaningful only for `getdata and `joinfn only for `execquery; the rest of the
/ lifecycle (postback wrapping, timeout, deferred-sync reply, purge) is common to both.
requestschema:([requestid:`u#`long$()]
  time:`timestamp$(); clienth:`int$(); remaining:`long$();
  mode:`symbol$(); by:(); aggs:(); joinfn:();
  postback:(); timeout:`timespan$();
  returntime:`timestamp$(); error:`boolean$(); sync:`boolean$());

/ --- internal helpers ---

normlog:{[logdict]
  / normalise an injected logger to a binary `info`warn`error!{[c;m]} dict (kx.log is monadic -
  / wrap and fold the context in); an already-binary dict passes through unchanged
  $[any `getlvl`sinks`fmts in key logdict;
    `info`warn`error!{[fn;c;m] fn[string[c],": ",m]}[;;]'[logdict`info`warn`error];
    logdict]
  };

raiseerror:{[ctx;msg] .z.m.log[`error][ctx;msg]; '"di.dataaccess: ",string[ctx],": ",msg};
getopt:{[deps;k;dflt] $[k in key deps;deps k;dflt]};

/ --- routing (which servertypes + sub-ranges cover [starttime;endtime]) ---

getrouting:{[starttime;endtime]
  active:exec distinct servertype from (.z.m.serverselect`getservers)[`servertype;`;()!()];
  parts:select from .z.m.partitions where servertype in active;
  shards:select servertype,rangestart:coverfrom|starttime,rangeend:coverto&endtime from parts;
  select from shards where rangestart<rangeend
  };

/ --- per-backend functional query building (the date-normalisation seam) ---

/ a by-column's per-servertype expression: the partition column (`date) is a native column on the
/ hdb but must be DERIVED (`date$time) on the rdb, which has no date column; other cols group by
/ themselves. Returns a functional-qSQL by-value (a column symbol or a parse tree).
/ `enlist`date` (not bare `date`) - in a parse tree a bare symbol is a COLUMN reference; the
/ literal cast-target symbol must be enlisted. So ($;enlist`date;tc) is `date$<timecol>`.
byexpr:{[servertype;tc;pc;c] $[c=pc; $[servertype=`hdb; pc; ($;enlist`date;tc)]; c]};

buildshardquery:{[servertype;tab;by;aggd;rs;re;tc;pc]
  / where: time within the shard range; on the hdb also constrain the partition column so kdb
  / prunes partitions instead of scanning every date's time column
  wc:enlist (within;tc;(rs;re));
  if[(servertype=`hdb) and not tc~pc; wc:wc,enlist (within;pc;(`date$rs;`date$re))];
  / no aggs -> plain row select (all cols), grouping ignored
  if[0=count aggd; :(?;tab;wc;0b;())];
  b:$[0=count by;0b;(by)!byexpr[servertype;tc;pc] each by];
  / expand each output col into its shard COMPONENT columns (compname!shardexpr), merge across cols
  a:(,/){[o;spec] cs:(aggspecs spec 0)0; (compname[o;]each cs[;0])!{[b;ic] b ic}[;spec 1]each cs[;1]}'[key aggd;value aggd];
  (?;tab;wc;b;a)
  };

/ --- string query building (the execquery entry point) ---

/ inject the shard's time range into a qSQL query STRING as a within filter on the time column,
/ appended as the last clause so it works whether or not the query already has a where.
/ String-based by design (from kdbx-modules feature-dataaccess, kept verbatim in behaviour): it
/ assumes a flat select string and is NOT robust to subqueries, fby, or the literal text "where"
/ inside a string constant. getdata's functional builder above has none of those limits - prefer
/ it where the query is structured; this exists for callers holding an arbitrary query string.
buildstringshardquery:{[query;rangestart;rangeend]
  clause:(string .z.m.timecolumn)," within (",(string rangestart),";",(string rangeend),")";
  $[query like "*where*";query," , ",clause;query," where ",clause]
  };

/ --- shard accumulation + reduce ---

shardresult:{[reqid;query;result]
  / asyncdispatch local postback: (reqid;query;result). Backend errors arrive as an
  / errorprefix-prefixed STRING through this same postback - detect and short-circuit.
  if[(10h=type result) and errorprefix~(count errorprefix) sublist result;
    :sharderror[reqid;(count errorprefix) _ result]];
  if[not reqid in key .z.m.requests;:()];
  if[not null .z.m.requests[reqid;`returntime];:()];
  .z.m.shardresults[reqid],:enlist result;
  n:.z.m.requests[reqid;`remaining]-1;
  .z.m.requests:update remaining:n from .z.m.requests where requestid=reqid;
  if[0=n;checkresults reqid];
  };

sharderror:{[reqid;err]
  if[not reqid in key .z.m.requests;:()];
  if[not null .z.m.requests[reqid;`returntime];:()];
  .z.m.log[`error][`sharderror;"shard error for request ",string[reqid],": ",err];
  sendreply[reqid;errorprefix,err;0b];
  finishrequest[reqid;1b];
  };

checkresults:{[reqid]
  / all shards in - recombine according to the request's mode, then reply.
  /   `getdata   - plain (no agg): raze the shard tables. Aggregated: re-group the razed shards on
  /                the by-keys applying each agg's REDUCE fn (count/sum->sum, min->min, max->max).
  /   `execquery - apply the caller's joinfn across the raw shard results (kdbx branch behaviour).
  req:.z.m.requests reqid;
  res:$[req[`mode]~`execquery;
    .[{(0b;x y)};(req`joinfn;.z.m.shardresults reqid);{(1b;errorprefix,"join failed: ",x)}];
    .[{[by;aggd;t]
        (0b; $[0=count aggd; t;
               ?[t; (); $[0=count by;0b;(by)!by];
                 (key aggd)!{[o;spec] cs:(aggspecs spec 0)0; ((aggspecs spec 0)1) compname[o;]each cs[;0]}'[key aggd;value aggd]]])};
      / 0! - grouped shard results are keyed; unkey before razing
      (req`by;req`aggs;raze 0!'.z.m.shardresults reqid); {(1b;errorprefix,"reduce failed: ",x)}]];
  if[res 0;.z.m.log[`error][`checkresults;"recombine failed for request ",string[reqid],": ",last res]];
  sendreply[reqid;last res;not res 0];
  finishrequest[reqid;res 0];
  };

sendreply:{[reqid;result;status]
  req:.z.m.requests reqid;
  if[req`error;:()];
  tosend:$[()~req`postback;result;req[`postback],enlist result];
  $[req`sync; @[-30!;(req`clienth;not status;result);{}]; @[neg req`clienth;tosend;()]];
  };

finishrequest:{[reqid;err]
  .z.m.shardresults:(reqid,()) _ .z.m.shardresults;
  .z.m.requests:update error:err,returntime:.z.m.cp[] from .z.m.requests where requestid=reqid;
  };

submitshards:{[reqid;shards;timeout]
  / one asyncdispatch call per shard, LOCAL mode (replyto 0Ni) so the reply comes back to
  / .dataaccess.shardresult (root-published) not the end client. join=first: a shard is a single
  / servertype, so asyncdispatch returns that one backend's result as-is for us to reduce.
  / NB execqueryto (not execquery): execquery captures clienth:.z.w at call time, which in-process
  / is the END CLIENT's handle, so the reply would bypass dataaccess entirely - the integration bug
  / the kdbx branch documented but could not fix from its side. replyto 0Ni is the local-mode fix.
  {[reqid;timeout;stype;q]
    (.z.m.asyncdispatch`execqueryto)[0Ni; q; enlist stype; first; (.z.m.resultcallback;reqid); timeout; 0b]
    }[reqid;timeout]'[shards`servertype; shards`shardquery];
  };

/ --- request lifecycle helpers (shared by both entry points) ---

/ guard a deferred-sync request: sync must be permitted by config AND supported by this connection.
checksync:{[ctx;sync]
  if[not sync;:()];
  if[not .z.m.synccallsallowed;raiseerror[ctx;"synchronous calls are not allowed"]];
  if[not @[{-30!x;1b};(::);0b];raiseerror[ctx;"deferred response not supported on this connection"]];
  };

/ nothing covers the requested range: reply empty, honouring postback wrapping and deferred sync,
/ and still burn a request id so ids stay monotonic. (kdbx branch behaviour - TorqX's getdata sent
/ a bare async empty and ignored postback/sync.)
replyempty:{[postback;sync;empty]
  tosend:$[()~postback;empty;postback,enlist empty];
  $[sync;@[-30!;(.z.w;0b;empty);{}];@[neg .z.w;tosend;()]];
  .z.m.requestid:1+.z.m.requestid;
  };

normpostback:{[postback] $[11h=abs type postback;(),postback;postback]};

/ build the one-row request table for an upsert. Deliberately an ENLISTED DICT rather than a bare
/ tuple: a row carrying more than one empty-list cell (e.g. an unused joinfn AND no postback) is
/ ambiguous to q - it cannot tell one row from a set of column vectors - and upsert throws 'type.
/ recombine: the mode-specific triple (by;aggs;joinfn) - passed as one argument because a q lambda
/ takes at most 8 parameters and the full row needs nine values ('params at load otherwise).
newrequest:{[reqid;nshards;mode;recombine;postback;timeout;sync]
  enlist `requestid`time`clienth`remaining`mode`by`aggs`joinfn`postback`timeout`returntime`error`sync!
    (reqid;.z.m.cp[];.z.w;nshards;mode;recombine 0;recombine 1;recombine 2;postback;timeout;0Np;0b;sync)
  };

/ --- public API ---

getdatafull:{[tablename;starttime;endtime;by;aggs;postback;timeout;sync]
  / by:   symbol list of grouping columns (`date normalised per backend); ` or () for none.
  / aggs: a (out;fn;incol) triple or a list of them, e.g. ((`cnt;`count;`i);(`vol;`sum;`size));
  /       ` or () for a plain row select. fn in `count`sum`min`max`avg`wavg`vwap.
  / postback: () for a plain reply, else (fn;args...) prepended to the result before sending.
  / timeout:  per-shard dispatch timeout (0Wn for none).
  / sync:     1b to answer the caller via a deferred (-30!) response; needs `synccallsallowed.
  if[not `log in key .z.m;'"di.dataaccess: init must be called before getdata"];
  checksync[`getdata;sync];
  by:(),$[(::)~by;`;by]; by:by where not null by;
  / -> list of (out;fn;incol) triples. A single triple is either a plain symbol triple (type 11h)
  / or, when incol is a (weight;value) pair (wavg/vwap), a generic list whose first item is a symbol
  / atom - distinguish from a list-of-triples (whose first item is itself a triple, not an atom).
  aggs:$[(::)~aggs;();
         11h=type aggs;enlist aggs;
         (0h=type aggs)and -11h=type first aggs;enlist aggs;
         aggs];
  aggs:aggs where 0<count each aggs;
  if[count aggs;
    fns:aggs[;1];
    if[count bad:distinct fns where not fns in key aggspecs;
      raiseerror[`getdata;"unsupported agg fn(s): ",(", " sv string bad),"; supported: ",", " sv string key aggspecs]];
    if[count pairaggs:aggs where fns in `wavg`vwap;
      if[not all 2=count each pairaggs[;2];
        raiseerror[`getdata;"wavg/vwap need a (weight;value) incol pair, e.g. (`vw;`vwap;`size`price)"]]]];
  aggd:$[0=count aggs;()!();(aggs[;0])!flip(aggs[;1];aggs[;2])];  / outcol!(fn;incol)
  postback:normpostback postback;
  shards:getrouting[starttime;endtime];
  if[0=count shards; :replyempty[postback;sync;()]];            / nothing covers the range -> empty
  qs:buildshardquery[;tablename;by;aggd;;;.z.m.timecolumn;.z.m.partitioncolumn]'[shards`servertype;shards`rangestart;shards`rangeend];
  shards:shards,'flip(enlist`shardquery)!enlist qs;
  reqid:.z.m.requestid;
  / upsert an ENLISTED DICT, not a bare tuple: with more than one empty-list cell (here joinfn and
  / an absent postback) q cannot tell a single row from a set of column vectors and throws 'type.
  .z.m.requests:.z.m.requests upsert newrequest[reqid;count shards;`getdata;(by;aggd;());postback;timeout;sync];
  .z.m.shardresults[reqid]:();
  submitshards[reqid;shards;timeout];
  .z.m.requestid:1+.z.m.requestid;
  };

/ simple form: no postback, no timeout, async. Delegates to getdatafull - same pairing convention
/ as di.proc.gateway's asyncexec/asyncexecjpt, so existing 5-arg .gw.getdata callers are unaffected.
/ NB must be defined AFTER getdatafull: a module-local name is rewritten to the module namespace at
/ COMPILE time, so a forward reference here silently falls through to root and throws 'type on call.
getdata:{[tablename;starttime;endtime;by;aggs]
  getdatafull[tablename;starttime;endtime;by;aggs;();0Wn;0b]
  };

execquery:{[query;starttime;endtime;joinfn;postback;timeout;sync]
  / STRING entry point (from kdbx-modules feature-dataaccess): route an arbitrary qSQL query string
  / across the partition coverage, rewrite each shard's time filter into the string, scatter, then
  / recombine with the caller's joinfn. Complements getdata: getdata is typed, date-normalising and
  / map-reducing but only builds the query shapes it knows; execquery takes any query string but
  / cannot normalise `date (the rdb has no date column) and leaves recombination to the caller.
  / Distinct from di.proc.gateway's .gw.asyncexecjpt, which sends one query to chosen servertypes
  / with no time-range routing at all - this shards a raw string across the time partitions.
  if[not `log in key .z.m;'"di.dataaccess: init must be called before execquery"];
  checksync[`execquery;sync];
  postback:normpostback postback;
  shards:getrouting[starttime;endtime];
  if[0=count shards; :replyempty[postback;sync;enlist[]]];
  qs:buildstringshardquery[query;;]'[shards`rangestart;shards`rangeend];
  shards:shards,'flip(enlist`shardquery)!enlist qs;
  reqid:.z.m.requestid;
  / by is `$() (an empty symbol VECTOR), not the ` atom: the by column is declared general, and the
  / FIRST row inserted fixes its type - an atom would collapse it to a simple symbol column and the
  / next getdata request (whose by IS a vector) would then fail the upsert with 'type.
  .z.m.requests:.z.m.requests upsert newrequest[reqid;count shards;`execquery;(`$();()!();joinfn);postback;timeout;sync];
  .z.m.shardresults[reqid]:();
  submitshards[reqid;shards;timeout];
  .z.m.requestid:1+.z.m.requestid;
  };

removerequests:{[age]
  .z.m.requests:delete from .z.m.requests where not null returntime, .z.m.cp[]>returntime+age;
  };

checkpartitions:{[t]
  if[not all `servertype`coverfrom`coverto in cols t;
    '"di.dataaccess: partitions table needs columns servertype, coverfrom, coverto"];
  };

/ swap the routing coverage table at runtime. The gateway calls this at EOD reloadend, after the
/ wdb has moved the just-ended day's partition into the hdb: "today" now belongs to the hdb and the
/ new day to the rdb, so the static-at-init coverage must be refreshed or post-EOD queries for the
/ rolled day would still route to the rdb (which has dropped it). Keep the ranges non-overlapping.
setpartitions:{[parts]
  checkpartitions parts;
  .z.m.partitions:parts;
  .z.m.log[`info][`setpartitions;"partition coverage refreshed: ",(", " sv string exec servertype from parts)];
  };

init:{[deps]
  if[99h<>type deps;'"di.dataaccess: deps must be a dict with `log and `timer keys"];
  if[not `log in key deps;'"di.dataaccess: log dependency is required"];
  if[99h<>type deps`log;'"di.dataaccess: log value must be a dict of `info`warn`error"];
  if[not all `info`warn`error in key deps`log;'"di.dataaccess: log dict needs `info`warn`error"];
  if[not `timer in key deps;'"di.dataaccess: timer dependency is required"];
  if[`partitions in key deps;checkpartitions deps`partitions];
  .z.m.log:normlog deps`log;
  .z.m.timer:deps`timer;
  .z.m.asyncdispatch:asyncdispatch;
  .z.m.serverselect:serverselect;
  .z.m.cp:getopt[deps;`cp;{.z.p}];
  .z.m.synccallsallowed:getopt[deps;`synccallsallowed;0b];
  .z.m.requestkeeptime:getopt[deps;`requestkeeptime;0D00:30];
  .z.m.resultcallback:getopt[deps;`resultcallback;`.dataaccess.shardresult];
  .z.m.partitions:getopt[deps;`partitions;defaultpartitions];
  .z.m.timecolumn:getopt[deps;`timecolumn;`time];
  .z.m.partitioncolumn:getopt[deps;`partitioncolumn;`date];
  .z.m.requests:requestschema;
  .z.m.shardresults:()!();
  .z.m.requestid:0;
  / publish the local-postback entry points at root so asyncdispatch's execqueryto can `value them
  set[`.dataaccess.shardresult;shardresult];
  set[`.dataaccess.sharderror;sharderror];
  .z.m.log[`info][`init;"di.dataaccess initialised"];
  (.z.m.timer`addjob)[`dataaccesspurge;removerequests;enlist .z.m.requestkeeptime;1800;1h;()!()];
  };
