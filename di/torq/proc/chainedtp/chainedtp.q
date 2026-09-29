/ di.torq.proc.chainedtp - chained tickerplant

init:{[config;deps]
  if[not `log in key deps;'"di.torq.proc.chainedtp: log dependency is required - see di.util.log"];
  if[not `timer in key deps;'"di.torq.proc.chainedtp: timer dependency is required - see di.timer"];
  if[not `handlers in key deps;'"di.torq.proc.chainedtp: handlers dependency is required - see di.torq.handlers"];
  .z.m.log:deps`log;
  .z.m.procname:config`procname;
  (use`di.pubsub)[`init][enlist[`log]!enlist deps`log];
  (deps[`handlers]`register)[`.z.pc;`;`stpps;0j;.stpps.closesub];
  (use`di.subscriptions)[`init][config;deps];
  {[config;k] if[k in key config;set[` sv `.ctp,k;config k]]}[config] each `tickerplantname`pubinterval`tpconnsleep`createlogfile`logdir`subscribeto`subscribesyms`replay`schema`clearlogonsubscription`tpcheckcycles;
  if[0<>(`long$.ctp.pubinterval) mod 1000000000;'"di.torq.proc.chainedtp: pubinterval must be a whole number of seconds"];
  (deps[`handlers]`register)[`.z.pc;`;`chainedtp;0j;{[y] if[.ctp.tph=y;.z.m.log[`error][`.z.pc;"lost connection to tickerplant : ",string .ctp.tickerplantname];exit 0]}];
  .ctp.upd:$[.ctp.createlogfile;
    $[.ctp.pubinterval;{[t;x] .ctp.writetolog[t;x];.ctp.batchpub[t;x];};{[t;x] .ctp.writetolog[t;x];.ctp.tickpub[t;x];}];
    $[.ctp.pubinterval;.ctp.batchpub;.ctp.tickpub]];
  if[not `upd in key `.;set[`upd;.ctp.upd]];
  .ps.initialise[];
  .servers.startupdepnamecycles[.ctp.tickerplantname;.ctp.tpconnsleep;.ctp.tpcheckcycles];
  .ctp.subscribe[];
  .ctp.tableschemas:{x!(0#)@'value@'x} (),$[any null .ctp.subscribeto;tables[`.];.ctp.subscribeto];
  if[.ctp.pubinterval;(deps[`timer]`addjob)[`publishalltables;.ctp.publishalltables;();`long$.ctp.pubinterval%0D00:00:01;2;()!()]];
  }

\d .

tptype:`chained;

tablelist:{.stpps.t}

.u.subdetails:{[tabs;syms]
  r:.ctp.sub[tabs;syms]; s:r`schema;
  if[-11h=type first s;s:enlist s];
  `tables`schemas`logfile`rowcount`date!(s[;0];s[;0]!s[;1];$[.ctp.createlogfile;r`logfile;`];$[.ctp.createlogfile;r`i;0];.u.d)
  }

\d .ctp

tickerplantname:@[value;`tickerplantname;`tickerplant1];
pubinterval:@[value;`pubinterval;0D00:00:00];
tpconnsleep:@[value;`tpconnsleep;10];
createlogfile:@[value;`createlogfile;0b];
logdir:@[value;`logdir;`:tplogs];
subscribeto:@[value;`subscribeto;`];
subscribesyms:@[value;`subscribesyms;`];
replay:@[value;`replay;0b];
schema:@[value;`schema;1b];
clearlogonsubscription:@[value;`clearlogonsubscription;0b];
tpcheckcycles:@[value;`tpcheckcycles;0W];

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
  s:.sub.getsubscriptionhandles[`;.ctp.tickerplantname;()!()];
  if[count s;
    subproc:first s;
    .ctp.tph:subproc`w;
    refreshtp @[tph;".u.d";.z.D];
    .z.m.log[`info][`subscribe;"subscribing to ", string subproc`procname];
    r:(use`di.subscriptions)[`subscribe][tph;subscribeto;subscribesyms;replay];
    .u.d::r`date];
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
  pubtables:$[any null .ctp.subscribeto;tables[`.];.ctp.subscribeto],();
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
  ` sv (.ctp.logdir;`$string[.z.m.procname],"_",string d)
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
  0 = count select from .sub.SUBSCRIPTIONS where procname in .ctp.tickerplantname, active}

sub:{[subtabs;subsyms]
  r:(`schema`icounts`i`logfile`d)!();
  r[`schema]:$[-11h=type subtabs;first;::] .u.sub\:[subtabs,();subsyms];
  if[subscribesyms~`;r[`icounts]:.u.icounts];
  if[createlogfile;r[`i]:.u.i;r[`logfile]:.u.L];
  r[`d]:.u.d;
  r
  }

\d .u

end:{[d]
  .z.m.log[`info][`end;"end of day invoked"];
  .ctp.publishalltables[];
  .ctp.refreshtp[d+1];
  (neg union[@[value;(`.stpps.allsubhandles;`);()]; @[{union/[(value x)[;;0]]};`.u.w;()]])@\:(`endofday;d)
  }

\d .

endofday:{[d] .u.end d}

