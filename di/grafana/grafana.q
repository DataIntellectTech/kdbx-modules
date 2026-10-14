/ grafana json datasource adaptor for kdb-x
/ implements the simpod json datasource api so a grafana server can query
/ kdb+ tables and timeseries data over http - the /search endpoint populates
/ the grafana dropdowns and the /query endpoint returns timeseries or table data

/ -----------------------------------------------------------------------------
/ configuration - load-time defaults; overridden via the deps dict in init and
/ read back through .z.m at every call site
/ -----------------------------------------------------------------------------

/ name of the time column used for timeseries queries
timecol:`time;
/ name of the sym column used to split data by instrument
sym:`sym;
/ how far back to look when finding distinct syms
timebackdate:2D;
/ number of ticks to return for table requests
ticks:1000;
/ delimiter separating the arguments within a query target
del:".";
/ allow f. function targets to evaluate arbitrary q (off by default - see grafana.md)
allowfunctions:0b;

/ json type for each kdb datatype, keyed by .Q.t character
types:.Q.t!`array`boolean,(3#`null),(5#`number),11#`string;
/ milliseconds between 1970.01.01 and 2000.01.01
epoch:946684800000;

/ internal flag - set true once the http handlers have been installed
wired:0b;

/ -----------------------------------------------------------------------------
/ request handling
/ -----------------------------------------------------------------------------

zpp:{[x]
  / parse a grafana http post request and dispatch to the matching handler
  / kdb passes .z.pp (requeststring;headers); requeststring is "<endpoint> <body>"
  / (method and leading / already stripped), so cut at the first space gives
  / (endpoint;body) - e.g. "query {...}" -> ("query";"{...}")
  r:(0;n?" ")cut n:first x;
  rqt:.j.k r 1;
  .z.m.log[`info][`grafana;"received ",(r 0)," request"];
  handler:$["query"~r 0;query;"search"~r 0;search;annotation];
  :.[handler;enlist rqt;{[e].z.m.log[`error][`grafana;"failed to process request: ",e];'e}];
  };

annotation:{[rqt]
  / annotation endpoint is not yet implemented
  .z.m.log[`warn][`grafana;"annotation url not yet implemented"];
  :`$"Annotation url nyi";
  };

query:{[rqt]
  / dispatch each target to the timeseries or table builder by its own type and
  / merge the per-target json arrays - grafana can send several targets at once
  tgts:rqt`targets;
  / a single target may arrive as a bare dict; normalise to a list of targets
  tgts:$[99h=type tgts;enlist tgts;tgts];
  / iterate by index so a list or a table of targets is handled the same way
  build:{[rqt;tgts;i]t:tgts i;r:@[rqt;`targets;:;t];$[t[`type]~"timeserie";tsfunc r;tbfunc r]};
  / strip the [ ] from each per-target array, drop empties, re-wrap as one array
  inners:{1_-1_x}each build[rqt;tgts]each til count tgts;
  inners:inners where 0<count each inners;
  :.h.hy[`json]"[",(","sv inners),"]";
  };

search:{[rqt]
  / build the grafana dropdown options from the tables available in the process
  tabs:tables[];
  symtabs:tabs where .z.m.sym in'cols each tabs;
  timetabs:tabs where .z.m.timecol in'cols each tabs;
  rsp:string tabs;
  if[count timetabs;
    rsp,:s1:prefix["t";string timetabs];
    rsp,:s2:prefix["g";string timetabs];
    / suffix the numeric columns for the graph and other panel options
    rsp,:raze(s2,'.z.m.del),/:'c1:string {cols[x] where`number=types(0!meta x)`t}each timetabs;
    rsp,:raze(prefix["o";string timetabs],'.z.m.del),/:'c1;
    if[count symtabs;
      / suffix the distinct syms for the timeseries and other panel options
      rsp,:raze(s1,'.z.m.del),/:'c2:string each finddistinctsyms'[timetabs];
      rsp,:raze(prefix["o";string timetabs],'.z.m.del),/:'{x[0]cross .z.m.del,'string finddistinctsyms x 1}each(enlist each c1),'timetabs;
     ];
   ];
  :.h.hy[`json].j.j rsp;
  };

finddistinctsyms:{[x]
  / distinct syms seen in table x within the configured lookback window
  :?[x;enlist(>;.z.m.timecol;(-;.z.p;.z.m.timebackdate));1b;{x!x}enlist .z.m.sym] .z.m.sym;
  };

prefix:{[c;s]
  / prefix string c and the delimiter to each string in s
  :(c,.z.m.del),/:s;
  };

/ -----------------------------------------------------------------------------
/ fetching the last n ticks
/ -----------------------------------------------------------------------------

diskvals:{[x]
  / last `ticks` rows of an on-disk partitioned table
  c:(count[x]-.z.m.ticks)+til .z.m.ticks;
  :get'[.Q.ind[x;c]];
  };

memvals:{[x]
  / last `ticks` rows of an in-memory table
  :get'[?[x;enlist(within;`i;count[x]-.z.m.ticks,0);0b;()]];
  };

catchvals:{[x]
  / try the on-disk path first, fall back to the in-memory path on error
  :@[diskvals;x;{[x;y]memvals x}[x]];
  };

/ -----------------------------------------------------------------------------
/ target parsing helpers
/ -----------------------------------------------------------------------------

istype:{[targ;char]
  / test whether the target is prefixed with char followed by the delimiter
  :(char,.z.m.del)~2#targ;
  };
isfunc:istype[;"f"];
istab:istype[;"t"];

resolvetab:{[t]
  / resolve a table-name symbol to its unkeyed table, rejecting anything that is
  / not a known table - the name is looked up, never evaluated as code
  if[not t in tables[];
    .z.m.log[`error][`grafana;"unknown table: ",string t];
    '"di.grafana: unknown table ",string t];
  :0!value t;
  };

evalfunc:{[s]
  / evaluate an f. function-target expression - gated behind allowfunctions
  / because it executes arbitrary q (disabled by default)
  if[not .z.m.allowfunctions;
    .z.m.log[`error][`grafana;"function target rejected; allowfunctions is disabled"];
    '"di.grafana: function targets are disabled (set allowfunctions to enable)"];
  :value s;
  };

/ -----------------------------------------------------------------------------
/ building json responses
/ -----------------------------------------------------------------------------

tabresponse:{[colname;coltype;rqt]
  / build a table response in the json datasource schema
  :.j.j enlist`columns`rows`type!(flip`text`type!(colname;coltype);catchvals rqt;`table);
  };

tbfunc:{[rqt]
  / process a table request and return the json datasource table response
  rqt:raze rqt[`targets]`target;
  symname:0b;
  / f. targets evaluate a q expression (opt-in); t./bare targets resolve a known
  / table by name and are never evaluated as code
  rqt:$[isfunc rqt;0!evalfunc $[istab 2_rqt;4_rqt;2_rqt];
        istab rqt;[parts:`$.z.m.del vs rqt;if[2<count parts;symname:parts 2];resolvetab parts 1];
        resolvetab(`$rqt)];
  colname:cols rqt;
  coltype:types(0!meta rqt)`t;
  / filter to a single sym if one was supplied in the target
  if[-11h=type symname;rqt:?[rqt;enlist(=;.z.m.sym;enlist symname);0b;()]];
  :tabresponse[colname;coltype;rqt];
  };

tsfunc:{[x]
  / process a timeseries request and route to the correct panel/sym builder
  targ:raze x[`targets]`target;
  / split the target into its delimited arguments
  numargs:count args:$[isfunc targ;(0;1+targ?.z.m.del)cut targ:2_targ;`$.z.m.del vs targ];
  / panel-type indicator (g/t/o) as a symbol - args 0 is a char string on the f.
  / path (take its first char) and already a symbol otherwise
  tyargs:$[10h=abs type args 0;`$1#args 0;args 0];
  coln:cols rqt:$[isfunc targ;0!evalfunc args 1;resolvetab args 1];
  / convert a timestamp to milliseconds since the unix epoch
  mil:{floor epoch+(`long$x)%1000000};
  / ensure the time column is a timestamp
  if["p"<>meta[rqt][.z.m.timecol;`t];rqt:@[rqt;.z.m.timecol;+;.z.D]];
  / restrict to the time range requested by grafana - grafana sends iso-8601 utc;
  / strip a trailing Z only if present rather than blindly dropping the last char
  range:"P"${$["Z"=last x;-1_x;x]}each x[`range]`from`to;
  rqt:?[rqt;enlist(within;.z.m.timecol;range);0b;()];
  / add the milliseconds-since-epoch column grafana expects
  rqt:@[rqt;`msec;:;mil rqt .z.m.timecol];
  / dispatch on the number of arguments and the panel type
  $[(2<numargs)and`g~tyargs;graphsym[args 2;rqt];
    (2<numargs)and`t~tyargs;tablesym[coln;rqt;args 2];
    (2=numargs)and`g~tyargs;graphnosym[coln;rqt];
    (2=numargs)and`t~tyargs;tablenosym[coln;rqt];
    (4=numargs)and`o~tyargs;othersym[args;rqt];
    (3=numargs)and`o~tyargs;othernosym[args 2;rqt];
    (2=numargs)and`o~tyargs;othernosym[coln except .z.m.timecol;rqt];
    `$"Wrong input"]
  };

buildnosym:{[x;y;z]
  / append one column's datapoints to the response accumulator
  :y,`target`datapoints!(z 0;value each ?[x;();0b;z!z]);
  };

nosymresponse:{[rqt;colname]
  / build a no-sym datapoints response across all requested columns
  :.j.j buildnosym[rqt]\[();colname];
  };

othernosym:{[coln;rqt]
  / timeseries response for a non-specific panel with no sym split
  colname:coln cross`msec;
  :nosymresponse[rqt;colname];
  };

graphnosym:{[coln;rqt]
  / timeseries response for a graph panel with no sym split (numeric columns only)
  coln:-1_coln where`number=types(0!meta rqt)`t;
  colname:coln cross`msec;
  :nosymresponse[rqt;colname];
  };

tablenosym:{[coln;rqt]
  / timeseries response for a table panel with no sym split
  coltype:types -1_(0!meta rqt)`t;
  :tabresponse[coln;coltype;rqt];
  };

othersym:{[args;rqt]
  / timeseries response for a non-specific panel returning a single sym's data
  outcol:args[2],`msec;
  data:flip value flip?[rqt;enlist(=;.z.m.sym;enlist args 3);0b;outcol!outcol];
  :.j.j enlist`target`datapoints!(args 3;data);
  };

graphsym:{[colname;rqt]
  / timeseries response for a graph panel returning each sym's data
  syms:`$string ?[rqt;();1b;{x!x}enlist .z.m.sym] .z.m.sym;
  outcol:colname,`msec;
  build:{[outcol;rqt;x;y]data:flip value flip?[rqt;enlist(=;.z.m.sym;enlist y);0b;outcol!outcol];:x,`target`datapoints!(y;data)};
  :.j.j build[outcol;rqt]\[();syms];
  };

tablesym:{[coln;rqt;symname]
  / timeseries response for a table panel filtered to a single sym
  coltype:types -1_(0!meta rqt)`t;
  rqt:?[rqt;enlist(=;.z.m.sym;enlist symname);0b;()];
  :tabresponse[coln;coltype;rqt];
  };

/ -----------------------------------------------------------------------------
/ initialisation
/ -----------------------------------------------------------------------------

normlog:{[logdict]
  / detect kx.log instance by presence of kx.log-specific keys (getlvl, sinks, fmts)
  / kx.log functions are monadic - wrap each into binary {[c;m]} and embed context in the message
  / plain {[c;m]} log dicts (info`warn`error only) pass through unchanged
  $[any `getlvl`sinks`fmts in key logdict;
    `info`warn`error!(
      {[fn;c;m] fn[string[c],": ",m]}[logdict`info;];
      {[fn;c;m] fn[string[c],": ",m]}[logdict`warn;];
      {[fn;c;m] fn[string[c],": ",m]}[logdict`error;]);
    logdict]
  };

isgrafana:{[x]
  / true if the request's header dict carries the X-Grafana-Org-Id header; guard
  / the type so a non-dict last element (malformed/non-http arg) falls through
  $[99h=type h:last x;(`$"X-Grafana-Org-Id")in key h;0b]
  };

sethandlers:{
  / wrap any existing .z.pp/.z.ph so grafana requests are intercepted and every
  / other request falls through to the original handler
  .z.m.prevpp:$[@[{value x;1b};`.z.pp;0b];.z.pp;{[x]}];
  .z.pp:{[x]$[.z.m.isgrafana x;.z.m.zpp x;.z.m.prevpp x]};
  .z.m.prevph:$[@[{value x;1b};`.z.ph;0b];.z.ph;{[x]}];
  .z.ph:{[x]$[.z.m.isgrafana x;"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n";.z.m.prevph x]};
  .z.m.wired:1b;
  };

init:{[deps]
  / wire the logging dependency and any configuration, then install the handlers
  / deps - a single dict holding the log dependency and any config overrides
  /   `log        - `info`warn`error!({[c;m]};{[c;m]};{[c;m]}) - required
  /   config keys - optional `timecol`sym`timebackdate`ticks`del, alongside `log
  / examples:
  /   grafana.init[enlist[`log]!enlist mylog]
  /   grafana.init[`log`ticks!(mylog;500)]
  / validate the required log dependency - nested guards, no eager `and`
  if[99h<>type deps;'"di.grafana: deps must be a dict with `log key"];
  if[not`log in key deps;'"di.grafana: log dependency is required; pass `info`warn`error functions keyed on `log"];
  if[99h<>type deps`log;'"di.grafana: log value must be a dict; pass `info`warn`error functions"];
  / normalise a kx.log instance into the binary {[c;m]} contract; plain dicts pass through
  lg:normlog deps`log;
  if[not all`info`warn`error in key lg;'"di.grafana: log dict must have `info`warn`error keys; got: ",", " sv string key lg];
  .z.m.log:lg;
  / overlay any supplied config - config values sit alongside `log in deps
  if[`timecol in key deps;.z.m.timecol:deps`timecol];
  if[`sym in key deps;.z.m.sym:deps`sym];
  if[`timebackdate in key deps;.z.m.timebackdate:deps`timebackdate];
  if[`ticks in key deps;.z.m.ticks:deps`ticks];
  if[`del in key deps;.z.m.del:deps`del];
  if[`allowfunctions in key deps;.z.m.allowfunctions:deps`allowfunctions];
  / install the http handlers once, preserving any existing definitions
  if[not .z.m.wired;sethandlers[]];
  .z.m.log[`info][`grafana;"initialised grafana json datasource adaptor"];
  };

getconfig:{
  / return the currently active configuration
  :`timecol`sym`timebackdate`ticks`del`allowfunctions!(.z.m.timecol;.z.m.sym;.z.m.timebackdate;.z.m.ticks;.z.m.del;.z.m.allowfunctions);
  };
