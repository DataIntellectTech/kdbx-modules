/ grafana json datasource adaptor for kdb-x
/ implements the simpod json datasource api so a grafana server can query
/ kdb+ tables and timeseries data over http - the /search endpoint populates
/ the grafana dropdowns and the /query endpoint returns timeseries or table data

/ -----------------------------------------------------------------------------
/ configuration - defaults applied here, overridden via the config dict in init
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
  / cut at the first whitespace to isolate the api url from any function params
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
  / dispatch a /query request to the timeseries or table builder by target type
  rqtype:raze rqt[`targets]`type;
  :.h.hy[`json]$[rqtype~"timeserie";tsfunc rqt;tbfunc rqt];
  };

search:{[rqt]
  / build the grafana dropdown options from the tables available in the process
  tabs:tables[];
  symtabs:tabs where sym in'cols each tabs;
  timetabs:tabs where timecol in'cols each tabs;
  rsp:string tabs;
  if[count timetabs;
    rsp,:s1:prefix["t";string timetabs];
    rsp,:s2:prefix["g";string timetabs];
    / suffix the numeric columns for the graph and other panel options
    rsp,:raze(s2,'del),/:'c1:string {cols[x] where`number=types(0!meta x)`t}each timetabs;
    rsp,:raze(prefix["o";string timetabs],'del),/:'c1;
    if[count symtabs;
      / suffix the distinct syms for the timeseries and other panel options
      rsp,:raze(s1,'del),/:'c2:string each finddistinctsyms'[timetabs];
      rsp,:raze(prefix["o";string timetabs],'del),/:'{x[0]cross del,'string finddistinctsyms x 1}each(enlist each c1),'timetabs;
     ];
   ];
  :.h.hy[`json].j.j rsp;
  };

finddistinctsyms:{[x]
  / distinct syms seen in table x within the configured lookback window
  :?[x;enlist(>;timecol;(-;.z.p;timebackdate));1b;{x!x}enlist sym]sym;
  };

prefix:{[c;s]
  / prefix string c and the delimiter to each string in s
  :(c,del),/:s;
  };

/ -----------------------------------------------------------------------------
/ fetching the last n ticks
/ -----------------------------------------------------------------------------

diskvals:{[x]
  / last `ticks` rows of an on-disk partitioned table
  c:(count[x]-ticks)+til ticks;
  :get'[.Q.ind[x;c]];
  };

memvals:{[x]
  / last `ticks` rows of an in-memory table
  :get'[?[x;enlist(within;`i;count[x]-ticks,0);0b;()]];
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
  :(char,del)~2#targ;
  };
isfunc:istype[;"f"];
istab:istype[;"t"];

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
  / strip the type prefix: f.t.func drops 4, f.func drops 2, t.tab leaves the
  / table name plus an optional sym
  rqt:0!value $[isfunc[rqt]&istab 2_rqt;4_rqt;
                isfunc rqt;2_rqt;
                istab rqt;[rqt:`$del vs rqt;if[2<count rqt;symname:rqt 2];rqt 1];
                rqt];
  colname:cols rqt;
  coltype:types(0!meta rqt)`t;
  / filter to a single sym if one was supplied in the target
  if[-11h=type symname;rqt:?[rqt;enlist(=;sym;enlist symname);0b;()]];
  :tabresponse[colname;coltype;rqt];
  };

tsfunc:{[x]
  / process a timeseries request and route to the correct panel/sym builder
  targ:raze x[`targets]`target;
  / split the target into its delimited arguments
  numargs:count args:$[isfunc targ;(0;1+targ?del)cut targ:2_targ;`$del vs targ];
  tyargs:$[10h=abs type args 0;`$1#;]args 0;
  coln:cols rqt:0!value args 1;
  / convert a timestamp to milliseconds since the unix epoch
  mil:{floor epoch+(`long$x)%1000000};
  / ensure the time column is a timestamp
  if["p"<>meta[rqt][timecol;`t];rqt:@[rqt;timecol;+;.z.D]];
  / restrict to the time range requested by grafana
  range:"P"$-1_'x[`range]`from`to;
  rqt:?[rqt;enlist(within;timecol;range);0b;()];
  / add the milliseconds-since-epoch column grafana expects
  rqt:@[rqt;`msec;:;mil rqt timecol];
  / dispatch on the number of arguments and the panel type
  $[(2<numargs)and`g~tyargs;graphsym[args 2;rqt];
    (2<numargs)and`t~tyargs;tablesym[coln;rqt;args 2];
    (2=numargs)and`g~tyargs;graphnosym[coln;rqt];
    (2=numargs)and`t~tyargs;tablenosym[coln;rqt];
    (4=numargs)and`o~tyargs;othersym[args;rqt];
    (3=numargs)and`o~tyargs;othernosym[args 2;rqt];
    (2=numargs)and`o~tyargs;othernosym[coln except timecol;rqt];
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
  data:flip value flip?[rqt;enlist(=;sym;enlist args 3);0b;outcol!outcol];
  :.j.j enlist`target`datapoints!(args 3;data);
  };

graphsym:{[colname;rqt]
  / timeseries response for a graph panel returning each sym's data
  syms:`$string ?[rqt;();1b;{x!x}enlist sym]sym;
  outcol:colname,`msec;
  build:{[outcol;rqt;x;y]data:flip value flip?[rqt;enlist(=;sym;enlist y);0b;outcol!outcol];:x,`target`datapoints!(y;data)};
  :.j.j build[outcol;rqt]\[();syms];
  };

tablesym:{[coln;rqt;symname]
  / timeseries response for a table panel filtered to a single sym
  coltype:types -1_(0!meta rqt)`t;
  rqt:?[rqt;enlist(=;sym;enlist symname);0b;()];
  :tabresponse[coln;coltype;rqt];
  };

/ -----------------------------------------------------------------------------
/ initialisation
/ -----------------------------------------------------------------------------

sethandlers:{
  / wrap any existing .z.pp/.z.ph so grafana requests are intercepted and every
  / other request falls through to the original handler
  .z.m.prevpp:$[@[{value x;1b};`.z.pp;0b];.z.pp;{[x]}];
  .z.pp:{[x]$[(`$"X-Grafana-Org-Id")in key last x;.z.m.zpp x;.z.m.prevpp x]};
  .z.m.prevph:$[@[{value x;1b};`.z.ph;0b];.z.ph;{[x]}];
  .z.ph:{[x]$[(`$"X-Grafana-Org-Id")in key last x;"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n";.z.m.prevph x]};
  .z.m.wired:1b;
  };

init:{[deps]
  / wire the logging dependency and any configuration, then install the handlers
  / deps - `log!enlist logdict or `log`config!(logdict;configdict)
  /   logdict    - `info`warn`error!({[c;m]};{[c;m]};{[c;m]}) - required
  /   configdict - optional overrides for `timecol`sym`timebackdate`ticks`del
  / examples:
  /   grafana.init[enlist[`log]!enlist mylog]
  /   grafana.init[`log`config!(mylog;enlist[`ticks]!enlist 500)]
  / validate the required log dependency - nested guards, no eager `and`
  if[99h<>type deps;'"di.grafana: deps must be a dict with `log key"];
  if[not`log in key deps;'"di.grafana: log dependency is required; pass `info`warn`error functions keyed on `log"];
  if[99h<>type deps`log;'"di.grafana: log value must be a dict; pass `info`warn`error functions"];
  if[not all`info`warn`error in key deps`log;'"di.grafana: log dict must have `info`warn`error keys; got: ",", " sv string key deps`log];
  .z.m.log:deps`log;
  / overlay any supplied configuration onto the defaults
  config:$[`config in key deps;deps`config;()!()];
  if[99h=type config;
    if[`timecol in key config;.z.m.timecol:config`timecol];
    if[`sym in key config;.z.m.sym:config`sym];
    if[`timebackdate in key config;.z.m.timebackdate:config`timebackdate];
    if[`ticks in key config;.z.m.ticks:config`ticks];
    if[`del in key config;.z.m.del:config`del];
   ];
  / install the http handlers once, preserving any existing definitions
  if[not wired;sethandlers[]];
  .z.m.log[`info][`grafana;"initialised grafana json datasource adaptor"];
  };

getconfig:{
  / return the currently active configuration
  :`timecol`sym`timebackdate`ticks`del!(timecol;sym;timebackdate;ticks;del);
  };
