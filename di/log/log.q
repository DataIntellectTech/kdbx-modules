/ simple stdout logger for di.* modules
/ provides info, warn, error, trace, debug, fatal with signature {[ctx;msg]}
/ ctx is a symbol context tag, msg is a string
/ also provides createLog, a factory for rich structured logger instances

/ os-aware newline
nl:$[.z.o in `w32`w64;"\r\n";"\n"];

/ log levels in priority order
lvls:`trace`debug`info`warn`error`fatal;

/ syslog severity per level (rfc5424)
syslogLvl:lvls!7 7 6 4 3 2i;

/ built-in format templates for createLog instances
fmts:`basic`syslog`raw!("$p $l PID[$i] HOST[$h] $m";"<$s> $m";"$m");

/ format pattern handlers for createLog instances; each takes {[level;msg]}
/ level is an uppercase string (e.g. "INFO"), msg is the formatted message string
pattern:"plihms~"!(
  {[x;y] string .z.p};
  {[x;y] x};
  {[x;y] string .z.i};
  {[x;y] string .z.h};
  {[x;y] y};
  {[x;y] string .z.M.syslogLvl`$lower x};
  {[x;y] "$"});

/ split a format template on delimiter, returning (textparts; substitutionfunctions)
/ escaped delimiter (e.g. $$) is replaced by $~ which resolves to literal $
fmtprep:{[del;rep;fmt]
  fmt:ssr[fmt;del,del;del,"~"];
  parts:del vs fmt;
  fns:rep@first each 1_parts;
  (enlist[first parts],1_/:1_parts;fns)
  };

/ apply a prepared format returning the assembled line string
/ level is an uppercase string, msg is the formatted message string
fmtapply:{[prep;level;msg]
  textparts:prep 0;
  fns:prep 1;
  vals:fns .\:(level;msg);
  raze first[textparts],vals,'1_textparts
  };

/ apply printf-style variable substitution to a message
/ msg is a plain string or (fmtstring;arg1;arg2;...)
/ %s converts to string, %r uses .Q.s1, %% becomes a literal percent
fmtmsg:{[msg]
  $[10h=abs type msg;
    msg;
    [fmt:first msg;
     args:1_msg;
     fmt:ssr[fmt;"%%";"\000"];
     parts:"%" vs fmt;
     subs:"sr"!({$[10h=abs type x;x;-11h=type x;string x;'`type]};.Q.s1);
     result:first[parts],raze {[subs;args;parts;i]
       part:parts[1+i];
       code:first part;
       rest:1_part;
       if[not code in key subs;'`$"unsupported format char: ",enlist code];
       (subs[code] args[i]),rest
     }[subs;args;parts;] each til count[parts]-1;
     ssr[result;"\000";"%"]
    ]
  ]};

/ format and write a log line to stdout using the dependency-contract format
logline:{[level;ctx;msg]
  -1 (string .z.p)," [",level,"] [",string[ctx],"] ",msg;
  };


/ instance counter and per-instance state; bare names fall back to .z.M when .z.m not yet set
i:0;
inst:()!();

/ factory helper: returns a 1-arg {[msg]} log function for the given level and instance
/ each entry in sink is a (handle;sender) pair; sender is called with the formatted text
makelevel:{[id;gv;lvl]
  {[id;gv;lvl;msg]
    if[(lvls?lvl)<lvls?gv`lvl;:()];
    txt:fmtapply[gv`prep;upper string lvl;fmtmsg msg],nl;
    {[txt;pair]
      @[last pair;txt;{x}]
    }[txt;] each (gv`sink)[lvl];
  }[id;gv;lvl;]
  };

/ update field k with value v in instance id's state
updInst:{[id;k;v]
  state:inst;
  state[id;k]:v;
  .z.m.inst:state;
  };


/ ============================================================
/ public api
/ ============================================================

/ simple dependency-contract-compatible log functions; each has signature {[ctx;msg]}
trace:{[ctx;msg] logline["TRACE";ctx;msg];};
debug:{[ctx;msg] logline["DEBUG";ctx;msg];};
info:{[ctx;msg] logline["INFO";ctx;msg];};
warn:{[ctx;msg] logline["WARN";ctx;msg];};
error:{[ctx;msg] logline["ERROR";ctx;msg];};
fatal:{[ctx;msg] logline["FATAL";ctx;msg];};

/ pre-wrapped log dependency dict ready to pass straight into any di.* module's init
/ e.g. email.init[mylog.defaultdict]
defaultdict:(enlist`log)!enlist(`info`warn`error!(info;warn;error));

/ create a logger instance with level filtering, multiple formatters and sinks
/ returns a dictionary of functions; each call returns an independent instance
/ sink entries are (handle;sender) pairs; sender is called with the formatted text
createLog:{[]
  / increment instance counter and capture id
  .z.m.i+:1;
  id:i;
  / initialise state for this instance; no separate handler dict needed
  snk:lvls!(count lvls)#enlist();
  prp:fmtprep["$";pattern;fmts`basic];
  state:inst;
  state[id]:`sink`lvl`fmtname`fmts`prep!(snk;`info;`basic;fmts;prp);
  .z.m.inst:state;

  / helpers that close over id to read and write this instance's state
  gv:{.z.m.inst[x][y]}[id;];
  wv:updInst[id;;];

  / set active format by name; recomputes the prepared format template
  setfmt:{[gv;wv;name]
    f:gv`fmts;
    if[not name in key f;'"invalid format: ",string name];
    wv[`prep;fmtprep["$";pattern;f name]];
    wv[`fmtname;name];
  }[gv;wv;];

  / get the current format name; 1-arg (dummy ignored) so gv executes in module context
  getfmt:{[gv;x] gv`fmtname}[gv;];

  / add a custom named format template string
  addfmt:{[gv;wv;name;fmt]
    wv[`fmts;@[gv`fmts;name;:;fmt]];
  }[gv;wv;;];

  / set minimum log level; messages below this level are suppressed
  setlvl:{[gv;wv;newlvl]
    if[not newlvl in lvls;'"invalid level: ",string newlvl];
    wv[`lvl;newlvl];
  }[gv;wv;];

  / get the current minimum log level; 1-arg (dummy ignored) so gv executes in module context
  getlvl:{[gv;x] gv`lvl}[gv;];

  / add a sink (handle or (handle;fn) pair) for one or more log levels
  / each sink entry is stored as (handle;sender) so mixed types never collide in a dict
  add:{[id;gv;h;sinklvls]
    handle:$[0h=type h;first h;h];
    sender:$[0h=type h;last h;h];
    {[id;handle;sender;lvl]
      state:.z.m.inst;
      sink:state[id;`sink];
      sink[lvl],:enlist(handle;sender);
      state[id;`sink]:sink;
      .z.m.inst:state;
    }[id;handle;sender;] each (),sinklvls;
    handle
  }[id;gv;;];

  / remove a handle from a log level's sink list
  remove:{[id;h;lvl]
    state:.z.m.inst;
    sink:state[id;`sink];
    sink[lvl]:sink[lvl] where {[h;p] not h~first p}[h;] each sink[lvl];
    state[id;`sink]:sink;
    .z.m.inst:state;
    h
  }[id;;];

  / initialise default sink: stdout for all levels
  add[1i;lvls];

  / return public interface as a dictionary of functions
  (lvls,`add`remove`setfmt`getfmt`addfmt`setlvl`getlvl)!
    (makelevel[id;gv;] each lvls),
    (add;remove;setfmt;getfmt;addfmt;setlvl;getlvl)
  };