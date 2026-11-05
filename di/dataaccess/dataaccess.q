/ query layer over the gateway: route a time-ranged request across time-partitioned backends,
/ build a per-backend query, scatter via di.asyncdispatch, then gather and reduce the results
/ getdata/getdatafull: typed, date-normalising, map-reducing; execquery: query string, caller joinfn

asyncdispatch:use`di.asyncdispatch;
serverselect:use`di.serverselect;

errorprefix:"error: ";

/ default coverage: one hdb over all time; override via init `partitions
defaultpartitions:([]servertype:enlist`hdb;coverfrom:enlist -0Wp;coverto:enlist 0Wp);

/ agg fn -> (components; reducefn): per-shard component columns (suffix ` is the output column,
/ else <out>__<suffix>) and the parse tree recombining them on the by-keys
compname:{[o;suffix] $[suffix~`;o;`$string[o],"__",string suffix]};
aggspecs:()!();
aggspecs[`count]:(enlist(`;{[c] (count;c)});                            {[cn] (sum;cn 0)});
aggspecs[`sum]:  (enlist(`;{[c] (sum;c)});                              {[cn] (sum;cn 0)});
aggspecs[`min]:  (enlist(`;{[c] (min;c)});                              {[cn] (min;cn 0)});
aggspecs[`max]:  (enlist(`;{[c] (max;c)});                              {[cn] (max;cn 0)});
aggspecs[`avg]:  (((`s;{[c] (sum;c)});(`n;{[c] (sum;(not;(null;c)))})); {[cn] ((%);(sum;cn 0);(sum;cn 1))});
aggspecs[`wavg]: (((`n;{[c] (sum;(*;c 0;c 1))});(`d;{[c] (sum;c 0)}));  {[cn] ((%);(sum;cn 0);(sum;cn 1))});
aggspecs[`vwap]: aggspecs`wavg;

/ one row per in-flight request; `mode is `getdata (map-reduce by/aggs) or `execquery (joinfn)
requestschema:([requestid:`u#`long$()]
  time:`timestamp$(); clienth:`int$(); remaining:`long$();
  mode:`symbol$(); by:(); aggs:(); joinfn:();
  postback:(); timeout:`timespan$();
  returntime:`timestamp$(); error:`boolean$(); sync:`boolean$());

/ --- internal helpers ---

normlog:{[logdict]
  / normalise an injected logger to a binary `info`warn`error {[c;m]} dict
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

/ a by-column's per-servertype expression: `date is derived as `date$time on the rdb
byexpr:{[servertype;tc;pc;c] $[c=pc; $[servertype=`hdb; pc; ($;enlist`date;tc)]; c]};

buildshardquery:{[servertype;tab;by;aggd;rs;re;tc;pc]
  / where: time within the shard range, plus the date partition on the hdb
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

/ append the shard's time range to a flat qSQL query string as a within filter
buildstringshardquery:{[query;rangestart;rangeend]
  clause:(string .z.m.timecolumn)," within (",(string rangestart),";",(string rangeend),")";
  $[query like "*where*";query," , ",clause;query," where ",clause]
  };

/ --- shard accumulation + reduce ---

shardresult:{[reqid;query;result]
  / local postback (reqid;query;result); an errorprefix string is a backend error
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
  / all shards in: map-reduce (`getdata) or apply joinfn (`execquery), then reply
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
  / one local-mode (replyto 0Ni) asyncdispatch call per shard, replying to .dataaccess.shardresult
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

/ reply empty when nothing covers the range, honouring postback and sync
replyempty:{[postback;sync;empty]
  tosend:$[()~postback;empty;postback,enlist empty];
  $[sync;@[-30!;(.z.w;0b;empty);{}];@[neg .z.w;tosend;()]];
  .z.m.requestid:1+.z.m.requestid;
  };

normpostback:{[postback] $[11h=abs type postback;(),postback;postback]};

/ the one-row request table as an enlisted dict; recombine is (by;aggs;joinfn)
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
  / -> list of (out;fn;incol) triples
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
  / upsert as an enlisted dict
  .z.m.requests:.z.m.requests upsert newrequest[reqid;count shards;`getdata;(by;aggd;());postback;timeout;sync];
  .z.m.shardresults[reqid]:();
  submitshards[reqid;shards;timeout];
  .z.m.requestid:1+.z.m.requestid;
  };

/ getdatafull with no postback, no timeout, async; defined after getdatafull
getdata:{[tablename;starttime;endtime;by;aggs]
  getdatafull[tablename;starttime;endtime;by;aggs;();0Wn;0b]
  };

execquery:{[query;starttime;endtime;joinfn;postback;timeout;sync]
  / route a qSQL query string across the time partitions, filter each shard by time, scatter,
  / then recombine with the caller's joinfn
  if[not `log in key .z.m;'"di.dataaccess: init must be called before execquery"];
  checksync[`execquery;sync];
  postback:normpostback postback;
  shards:getrouting[starttime;endtime];
  if[0=count shards; :replyempty[postback;sync;enlist[]]];
  qs:buildstringshardquery[query;;]'[shards`rangestart;shards`rangeend];
  shards:shards,'flip(enlist`shardquery)!enlist qs;
  reqid:.z.m.requestid;
  / by is an empty symbol vector so the general by column is not typed by the first row
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

/ replace the routing coverage table, e.g. at eod reload; ranges must not overlap
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
  (.z.m.timer`addjob)[`dataaccesspurge;removerequests;enlist .z.m.requestkeeptime;0D00:30;1h;()!()];
  };
