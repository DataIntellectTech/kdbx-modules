/ di.torq.proc.chainedtp - chained tickerplant

/ a timespan, a "0D00:00:01" string or a number of seconds (TOML has no timespan type)
totimespan:{[x] $[-16h=type x;x;10h=abs type x;"N"$(),x;-11h=type x;"N"$string x;type[x] in -5 -6 -7h;0D00:00:01*x;0Nn]};

/ a symbol, a string or a list of strings (TOML has no symbol type)
tosym:{[x] $[type[x] in 0 10 -10h;`$x;x]};

init:{[config;deps]
  if[not `log in key deps;'"di.torq.proc.chainedtp: log dependency is required - see di.util.log"];
  if[not `timer in key deps;'"di.torq.proc.chainedtp: timer dependency is required - see di.timer"];
  if[not `handlers in key deps;'"di.torq.proc.chainedtp: handlers dependency is required - see di.torq.handlers"];
  / all settings required
  req:`tickerplantname`pubinterval`tpconnsleep`createlogfile`logdir`subscribeto`subscribesyms`replay`schema`clearlogonsubscription`tpcheckcycles;
  if[count m:req except key config;'"di.torq.proc.chainedtp: missing settings: ",", " sv string m];
  .z.m.log:deps`log;
  .z.m.procname:config`procname;
  (use`di.pubsub)[`init][enlist[`log]!enlist deps`log];
  (deps[`handlers]`register)[`.z.pc;`;`stpps;0j;.stpps.closesub];
  (use`di.subscriptions)[`init][config;deps];
  .z.m.tickerplantname:tosym config`tickerplantname;
  .z.m.pubinterval:totimespan config`pubinterval;
  .z.m.tpconnsleep:config`tpconnsleep;
  .z.m.createlogfile:config`createlogfile;
  .z.m.logdir:$[10h=type l:config`logdir;hsym`$l;l];
  .z.m.subscribeto:tosym config`subscribeto;
  .z.m.subscribesyms:tosym config`subscribesyms;
  .z.m.replay:config`replay;
  .z.m.schema:config`schema;
  .z.m.clearlogonsubscription:config`clearlogonsubscription;
  .z.m.tpcheckcycles:config`tpcheckcycles;
  if[0<>(`long$pubinterval) mod 1000000000;'"di.torq.proc.chainedtp: pubinterval must be a whole number of seconds"];
  (deps[`handlers]`register)[`.z.pc;`;`chainedtp;0j;{[y] if[tph=y;.z.m.log[`error][`.z.pc;"lost connection to tickerplant : ",string tickerplantname];exit 0]}];
  .z.m.upd:$[createlogfile;
    $[pubinterval;{[t;x] writetolog[t;x];batchpub[t;x];};{[t;x] writetolog[t;x];tickpub[t;x];}];
    $[pubinterval;batchpub;tickpub]];
  if[not `upd in key `.;set[`upd;upd]];
  .ps.initialise[];
  .servers.startupdepnamecycles[tickerplantname;tpconnsleep;tpcheckcycles];
  subscribe[];
  .z.m.tableschemas:{x!(0#)@'value@'x} (),$[any null subscribeto;tables[`.];subscribeto];
  if[pubinterval;(deps[`timer]`addjob)[`publishalltables;publishalltables;();`long$pubinterval%0D00:00:01;2;()!()]];
  }

/ root: the subscriber contract
@[`.;`tptype;:;`chained];

@[`.;`tablelist;:;{.stpps.t}];

@[`.;`subdetails;:;{[tabs;instruments]
  r:sub[tabs;instruments];
  `schemalist`logfilelist`rowcounts`date!r@/:(`schema;$[r[`logfile]~();();enlist`i`logfile];`icounts;`d)
  }];

.u.subdetails:{[tabs;syms]
  r:sub[tabs;syms]; s:r`schema;
  if[-11h=type first s;s:enlist s];
  `tables`schemas`logfile`rowcount`date!(s[;0];s[;0]!s[;1];$[createlogfile;r`logfile;`];$[createlogfile;r`i;0];.u.d)
  }

tph:0N;
.u.icounts:.u.jcounts:(`symbol$())!0#0,();
.u.i:.u.j:0;

clearlog:{[lgfile]
  if[not type key lgfile;:()];
  .z.m.log[`info][`clearlog;"clearing log file : ",string lgfile];
  .[set;(lgfile;());{.z.m.log[`error][`clearlog;"cannot empty tickerplant log: ", x]}]
  }

openlog:{[lgfile]
  lgfileexists:type key lgfile;
  .z.m.log[`info][`openlog;
    $[lgfileexists;
      "opening log file : ";
      "creating new log file : "],string lgfile];
  if[not lgfileexists;
    .[set;(lgfile;());{[lgf;err] .z.m.log[`error][`openlog;"cannot create new log file : ",string[lgf]," : ", err]}[lgfile]]];
  updold:`. `upd;
  @[`.;`upd;:;{[t;x] .u.icounts[t]+:count x;}];
  .u.i:.u.j:@[-11!;lgfile;-11!(-2;lgfile)];
  @[`.;`upd;:;updold];
  if[0<=type .u.i;
    .z.m.log[`error][`openlog;"log file : ",(string lgfile)," is corrupt. Please remove and restart."]];
  hopen lgfile
  }

subscribe:{[]
  s:.sub.getsubscriptionhandles[`;tickerplantname;()!()];
  if[count s;
      subproc:first s;
      .z.m.tph:subproc`w;
      refreshtp @[tph;".u.d";.z.D];
      .z.m.log[`info][`subscribe;"subscribing to ", string subproc`procname];
      r:.sub.subscribe[subscribeto;subscribesyms;schema;replay;subproc];
      if[`d in key r;.u.d::r[`d]];
      if[(`icounts in key r) & (not createlogfile);
	subtabs:$[subscribeto~`;key r`icounts;subscribeto],();
	.u.jcounts::.u.icounts::$[0=count r`icounts;()!();subtabs!enlist [r`icounts]subtabs];
      ]
    ];
  }

writetolog:{[t;x]
   if[not 98h=type x;x:flip cols[value t]!(),/:x];
  .u.l enlist (`upd;t;x);
  .u.j+:1;
  }

tickpub:{[t;x]
  .ps.publish[t;x];
  .u.i:.u.j;
  .u.icounts[t]+:count x;
  }

batchpub:{[t;x]
  insert[t;x];
  .u.jcounts[t]+:count x;
  }

publishalltables:{[]
  pubtables:$[any null subscribeto;tables[`.];subscribeto],();
  .ps.publish'[pubtables;value each pubtables];
  cleartables[pubtables];
  .u.i:.u.j;
  .u.icounts:.u.jcounts;
  }

tableschemas:()!()

cleartables:{[t]
  @[`.;t;:;tableschemas t];
  }

createlogfilename:{[d]
  ` sv (logdir;`$string[procname],"_",string d)
  }

refreshtp:{[d]
  if[@[value;`.u.l;0]; @[hclose;.u.l;()]];
  .u.i:.u.j:0;
  .u.icounts::.u.jcounts::(`symbol$())!0#0,();
  if[createlogfile;
    .u.L:createlogfilename[d];
    if[clearlogonsubscription;clearlog .u.L];
  ];
  .u.l:$[createlogfile;openlog .u.L;1i];
  .u.d:d;
  }

notpconnected:{[]
  0 = count select from .sub.SUBSCRIPTIONS where procname in .z.m.tickerplantname, active}

sub:{[subtabs;subsyms]
  r:(`schema`icounts`i`logfile`d)!();
  r[`schema]:$[-11h=type subtabs;first;::] .u.sub\:[subtabs,();subsyms];
  if[subscribesyms~`;r[`icounts]:.u.icounts];
  if[createlogfile;r[`i]:.u.i;r[`logfile]:.u.L];
  r[`d]:.u.d;
  r
  }

/ root: the upstream ends the day
.u.end:{[d]
  .z.m.log[`info][`end;"end of day invoked"];
  publishalltables[];
  refreshtp[d+1];
  (neg union[@[value;(`.stpps.allsubhandles;`);()]; @[{union/[(value x)[;;0]]};`.u.w;()]])@\:(`.u.end;d)
  }
