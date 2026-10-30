/ subscribe to a tickerplant via .u.subdetails: define tables at root, replay the tp log up to
/ the subscription rowcount, then receive live updates through root `upd`

/ registry of active subscriptions
SUBSCRIPTIONS:([]handle:`int$();tabs:();syms:();subtime:`timestamp$())

/ .sub .z.pc handler and check job are registered once
registered:0b

/ a timespan, string, symbol or number of seconds as a timespan; null if not convertible
totimespan:{[x] $[-16h=type x;x;10h=abs type x;"N"$(),x;-11h=type x;"N"$string x;type[x] in -5 -6 -7h;0D00:00:01*x;0Nn]};

init:{[config;deps]
  if[not `log in key deps;'"di.subscriptions: log dependency is required - see di.util.log"];
  if[not `timer in key deps;'"di.subscriptions: timer dependency is required - see di.timer"];
  if[not `handlers in key deps;'"di.subscriptions: handlers dependency is required - see di.torq.handlers"];
  .z.m.log:deps`log;
  .z.m.tp:use`di.tplogmgr;          / for replayupto (repair-aware, count-limited -11!)
  / all settings required
  if[count m:`autoreconnect`checksubscriptionperiod except key config;'"di.subscriptions: missing settings: ",", " sv string m];
  .z.m.autoreconnect:config`autoreconnect;
  p:totimespan config`checksubscriptionperiod;
  if[null p;'"di.subscriptions: checksubscriptionperiod must be a timespan"];
  .z.m.checksubscriptionperiod:(not @[value;`.proc.lowpowermode;0b])*p;
  if[not .z.m.registered;
    (deps[`handlers]`register)[`.z.pc;`;`sub;0j;pc[::;]];
    if[checksubscriptionperiod>0;(deps[`timer]`addjob)[`checksubscriptions;checksubscriptions;();checksubscriptionperiod;1;()!()]];
    .z.m.registered:1b];
  }

/ root `upd` during replay: forward only subscribed tables and syms to origupd; x: columns, sym second
replayfilter:{[origupd;tabs;syms;t;x]
  if[not $[tabs~`;1b;t in tabs]; :()];        / skip tables we didn't subscribe to
  if[not syms~`; x:x@\:where x[1] in syms];   / keep only subscribed syms (col 1)
  origupd[t;x];
  }

/ protected count-limited replay through root `upd`; returns the count, or (`replayerr;e).
runreplay:{[lf;n] .[{[m;lf;n](m`replayupto)[lf;n]};(.z.m.tp;lf;n);{[e](`replayerr;e)}]}

/ replay the tp log up to sd`rowcount through root `upd`, wrapped by replayfilter if narrowed
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

/ subscribe over an open tickerplant handle; tabs/syms: ` for all; returns the subdetails dict
subscribe:{[tph;tabs;syms;replay]
  sd:tph(`.u.subdetails;tabs;syms);
  / define the subscribed tables at root
  {@[`.;x;:;y]}'[key sd`schemas;value sd`schemas];
  if[replay and 0<sd`rowcount; doreplay[sd;tabs;syms]];
  .z.m.SUBSCRIPTIONS:.z.m.SUBSCRIPTIONS,([]handle:enlist tph;tabs:enlist sd`tables;syms:enlist syms;subtime:enlist .z.p);
  .z.m.log[`info][`subscriptions;"subscribed to ",(", " sv string sd`tables)," on tickerplant handle ",string tph];
  sd
  }

/ whether any subscription is active
subscribed:{[] 0<count .z.m.SUBSCRIPTIONS}

/ the active-subscriptions registry (introspection)
getsubscriptions:{[] .z.m.SUBSCRIPTIONS}

/ root, for subscribers and their tests: proctype/procname subscriptions over di.torq.servers
.sub.SUBSCRIPTIONS:([]procname:`symbol$();proctype:`symbol$();w:`int$();table:();instruments:();createdtime:`timestamp$();active:`boolean$());

.sub.getsubscriptionhandles:{[proctype;procname;attributes]
  data:{select procname,proctype,w from x}each .servers.getservers[;;attributes;1b;0b]'[`proctype`procname;(proctype;procname)];
  $[0h in type each (proctype;procname);distinct raze data;inter/[data]]
 }

updatesubscriptions:{[proc;tab;instrs]
  delete from `.sub.SUBSCRIPTIONS where not active;
  if[instrs~`;instrs,:()];
  .sub.SUBSCRIPTIONS::0!(4!.sub.SUBSCRIPTIONS)upsert enlist proc,`table`instruments`createdtime`active!(tab;instrs;.z.p;1b);
 }

reconnectinit:0b;

reducesubs:{[tabs;utabs;instrs;proc]
  subtabs:$[tabs~`;utabs;tabs],();
  .z.m.log[`info][`subscribe;"attempting to subscribe to ",(","sv string subtabs)," on handle ",string proc`w];
  if[not instrs~`; instrs,:()];
  s:select from .sub.SUBSCRIPTIONS where ([]procname;proctype;w)~\:proc, table in subtabs,instruments~\:instrs, active;
  if[count s;
    .z.m.log[`info][`subscribe;"already subscribed to specified instruments from  ",(","sv string s`table)," on handle ",string proc`w];
    subtabs:subtabs except s`table];
  if[count errtabs:subtabs except utabs;
    .z.m.log[`info][`subscribe;"tables ",("," sv string errtabs)," are not available to be subscribed to, they will be ignored"];
    subtabs:subtabs inter utabs;];
  :`subtabs`errtabs`instrs!(subtabs;errtabs;instrs)
 }

createtables:{
  .z.m.log[`info][`subscribe;"setting the schema definition"];
  (@[`.;;:;].)each x where not 0=count each x;
 }

replay:{[tabs;realsubs;schemalist;logfilelist]
  .z.m.log[`info][`subscribe;"replaying the log file(s)"];
  origupd:@[value;`..upd;{{[x;y]}}];
  subtabs:realsubs[`subtabs];
  if[count where nullschema:0=count each schemalist;
    tabs:(schemalist where not nullschema)[;0];
    subtabs:tabs inter realsubs[`subtabs]];
  if[not (tabs;realsubs[`instrs])~(`;`);
    .z.m.log[`info][`subscribe;"using the replayupd function as not replaying all tables or instruments"];
    @[`.;`upd;:;replayupd[origupd;subtabs;realsubs[`instrs]]]];
  {[d] @[{.z.m.log[`info][`subscribe;"replaying log file ",.Q.s1 x]; -11!x;};d;{.z.m.log[`error][`subscribe;"could not replay the log file: ", x]}]}each logfilelist;
  @[`.;`upd;:;origupd];
  .z.m.log[`info][`subscribe;"finished log file replay"];
  @[realsubs;`subtabs;:;subtabs]
 }

.sub.subscribe:{[tabs;instrs;setschema;replaylog;proc]
  if[0=count proc;.z.m.log[`info][`subscribe;"no connections made"]; :()];
  if[(not reconnectinit)&autoreconnect;
    $[.servers.enabled;
      [.servers.connectcustom:{x@y;resubscribe[y]}[.servers.connectcustom]; .z.m.reconnectinit:1b];
      .z.m.log[`info][`subscribe;"autoreconnect was set to true but server functionality is disabled - unable to use autoreconnect"]];
   ];
  tptype:@[proc`w;({@[value;`tptype;`standard]};`);`];
  if[null tptype; .z.m.log[`error][`subscribe;e:"could not determine tickerplant type"]; 'e];
  $[tptype=`standard;
    [tablesfunc:{key `.u.w};
      subfunc:{`schemalist`logfilelist`rowcounts`date!(.u.sub\:[x;y];enlist(.u`i`L);(.u `icounts);(.u `d))}];
    tptype in `chained`segmented;
    [tablesfunc:`tablelist;
      subfunc:`subdetails];
    [.z.m.log[`error][`subscribe;e:"unrecognised tickerplant type: ",string tptype]; 'e]];
  utabs:@[proc`w;(tablesfunc;`);()];
  realsubs:reducesubs[tabs;utabs;instrs;proc];
  if[0=count realsubs`subtabs;
    .z.m.log[`info][`subscribe;"all tables have already been subscribed to"];
    :()];
  details:@[proc`w;(subfunc;realsubs[`subtabs];realsubs[`instrs]);{.z.m.log[`error][`subscribe;"subscribe failed : ",x];()}];
  if[count details;
    if[setschema;createtables[details[`schemalist]]];
    if[replaylog;realsubs:replay[tabs;realsubs;details[`schemalist];details[`logfilelist]]];
    .z.m.log[`info][`subscribe;"subscription successful"];
    updatesubscriptions[proc;;realsubs[`instrs]]each realsubs[`subtabs]];
  logdate:0Nd;
  if[tptype in `standard`chained;
    d:(`subtables`tplogdate!(details[`schemalist][;0];(first "D" $ -10 sublist string last first details[`logfilelist])^logdate));
    :d,{(where 101 = type each x)_x}(`i`icounts`d)!(details[`logfilelist][0;0];details[`rowcounts];details[`date])];
  if[tptype~`segmented;
    retdic:`logdir`subtables!(details[`logdir];details[`schemalist][;0]);
    :retdic,{(where 101 = type each x)_x}`i`icounts`d`tplogdate!details[`logfilelist`rowcounts`date`date];
    ]
 }

replayupd:{[f;tabs;syms;t;x]
  if[not (t in tabs) or tabs ~ `;:()];
  if[(syms ~ `)or 99=type syms; f[t;x];:()];
  c:cols[`. t];
  x:select from $[type[x] in 98 99h; x; 0>type first x;enlist c!x;flip c!x] where sym in syms;
  f[t;x]
 }

checksubscriptions:{update active:0b from `.sub.SUBSCRIPTIONS where not w in key .z.W;}

retrysubscription:{[row]
  .sub.subscribe[row`table;$[((),`) ~ insts:row`instruments;`;insts];0b;0b;3#row];
 }

resubscribe:{[rows]
  s:select from .sub.SUBSCRIPTIONS where ([]procname;proctype)in (select procname, proctype from rows), not active;
  s:s lj 2!select procname,proctype,w from rows;
  if[count s;retrysubscription each s];
 }

pc:{[result;W] update active:0b from `.sub.SUBSCRIPTIONS where w=W;result}
