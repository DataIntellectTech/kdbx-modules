/ periodic tp logging

/ live logs and handles to logs for each table
@[`.;`currlog;:;([tbl:`symbol$()]logname:`symbol$();handle:`int$())];

/ view of log file handles for faster lookups
value"loghandles::exec tbl!handle from currlog";

/ settings
.stplg.multilog:`tabperiod                            / [tabperiod|none|periodic|tabular|custom]
.stplg.multilogperiod:0D01
.stplg.errmode:1b
.stplg.batchmode:`defaultbatch                        / [memorybatch|defaultbatch|immediate]
.stplg.replayperiod:`day                              / [period|day|prior]
.stplg.customcsv:`
.stplg.kdbtplog:`$getenv`KDBTPLOG

.stplg.errorlogname:@[value;`.stplg.errorlogname;`segmentederrorlogfile]

/ create log directory `:stplogs/date/tabname_time
.stplg.createdld:{[name;date]
  if[not count dir:hsym .stplg.kdbtplog;.z.m.log[`error][`stp;"log directory not defined"];exit 1];
  system"mkdir -p ",1_string dir;
  system"mkdir -p ",1_string .stplg.dldir:` sv dir,`$raze/[string name,"_",date];
 };

.stplg.gentimeformat:{(raze string "dv"$x) except ".:"};

/ tabperiod: one log per table, rolled periodically
.stplg.logname.tabperiod:{[dir;tab;p] ` sv (hsym dir;`$raze string (.z.m.procname;"_";tab),.stplg.gentimeformat[p]) };

/ singular: one log, rolled daily
.stplg.logname.singular:{[dir;tab;p] ` sv (hsym dir;`$raze string .z.m.procname,"_",.stplg.gentimeformat[p]) };

/ periodic: one log, rolled periodically
.stplg.logname.periodic:{[dir;tab;p] ` sv (hsym dir;`$raze string .z.m.procname,"_periodic",.stplg.gentimeformat[p]) };

/ tabular: one log per table, rolled daily
.stplg.logname.tabular:{[dir;tab;p] ` sv (hsym dir;`$raze string (.z.m.procname;"_";tab),.stplg.gentimeformat[p]) };

/ custom: mode per table from the custom csv; tables not in it are not logged
.stplg.logname.custom:{[dir;tab;p] .stplg.logname[.stplg.custommode tab][dir;tab;p] };

.stplg.logname.error:{[dir;ename;p] ` sv (hsym dir;`$raze string (.z.m.procname;"_";ename),.stplg.gentimeformat[p]) };

/ upd and timer functions per batch mode; pre-existing definitions kept
.stplg.upd:@[value;`.stplg.upd;enlist[`]!enlist ()];
.stplg.zts:@[value;`.stplg.zts;enlist[`]!enlist ()];

/ functions to add columns on updates
.stplg.updtab:@[value;`.stplg.updtab;enlist[`]!enlist {(enlist(count first x)#y),x}]

/ memorybatch: insert in memory; write, publish and count on the timer
.stplg.upd[`memorybatch]:{[t;x;now]
  t insert .stplg.updtab[t] . (x;now);
 };

.stplg.zts[`memorybatch]:{
  {[t]
    if[count value t;
      `..loghandles[t] enlist (`upd;t;value flip value t);
      @[`.stplg.msgcount;t;+;1];
      @[`.stplg.rowcount;t;+;count value t];
      .stpps.pubclear[t]];
  }each .stpps.t;
 };

/ defaultbatch: write immediately, publish on the timer
.stplg.upd[`defaultbatch]:{[t;x;now]
  t insert x:.stplg.updtab[t] . (x;now);
  `..loghandles[t] enlist(`upd;t;x);
  @[`.stplg.tmpmsgcount;t;+;1];
  @[`.stplg.tmprowcount;t;+;count first x];
 };

.stplg.zts[`defaultbatch]:{
  .stpps.pubclear[.stpps.t];
  .stplg.msgcount+:.stplg.tmpmsgcount;
  .stplg.rowcount+:.stplg.tmprowcount;
  .stplg.tmpmsgcount:.stplg.tmprowcount:()!();
 };

/ immediate: write and publish immediately
.stplg.upd[`immediate]:{[t;x;now]
  x:.stplg.updtab[t] . (x;now);
  `..loghandles[t] enlist(`upd;t;x);
  x:$[0h>type last x;enlist;flip] .stpps.tabcols[t]!x;
  @[`.stplg.msgcount;t;+;1];
  @[`.stplg.rowcount;t;+;count x];
  .stpps.pub[t;x]
 };

.stplg.zts[`immediate]:{}

/ logcounts and lognames for client replay
.stplg.replaylog:{[t]
  .stplg.getlogs[.stplg.replayperiod][t]
 }

.stplg.getlogs:enlist[`]!enlist ()

/ period: logs for the current logging period
.stplg.getlogs[`period]:{[t]
  distinct flip (.stplg.msgcount;exec tbl!logname from `..currlog where tbl in t)@\:t
 };

/ day: all of today's logs; closed logs count 0W
.stplg.getlogs[`day]:{[t]
  lnames:select seq,tbls,logname,msgcount:0Wj from .stpm.metatable where any each tbls in\: t;
  lnames:update msgcount:sum each .stplg.msgcount[tbls] from lnames where seq=.stplg.i;
  flip value exec `long$msgcount,logname from lnames
 };

/ open log for a table at the start of a logging period
.stplg.openlog:{[multilog;dir;tab;p]
  lname:.stplg.logname[multilog][dir;tab;p];
  .z.m.log[`info][`openlog;"opening logfile: ",string lname];
  h:$[(notexists:not type key lname)or null h0:exec first handle from `..currlog where logname=lname;
    [if[notexists;.[lname;();:;()]];hopen lname];
    h0
  ];
  `..currlog upsert (tab;lname;h);
 };

/ error log for failed updates in error mode
.stplg.openlogerr:{[dir]
  lname:.[.stplg.logname.error;(dir;.stplg.errorlogname;.z.p+.z.m.eod.getdailyadj[]);{.z.m.log[`error][`openlogerr;"failed to make error log: ",x]}];
  if[not type key lname;.[lname;();:;()]];
  h:@[{hopen x};lname;{.z.m.log[`error][`openlogerr;"failed to open handle to error log with error: ",x]}];
  `..currlog upsert (.stplg.errorlogname;lname;h);
 };

.stplg.badmsg:{[e;t;x]
  .z.m.log[`info][`upd;"Bad message received, error: ",e];
  `..loghandles[.stplg.errorlogname] enlist(`upderr;t;x);
 };

.stplg.closelog:{[tab]
  if[null h:`..currlog[tab;`handle];.z.m.log[`info][`closelog;"no open handle to log file"];:()];
  .z.m.log[`info][`closelog;"closing log file ",string `..currlog[tab;`logname]];
  @[hclose;h;{.z.m.log[`error][`closelog;"handle already closed"]}];
  update handle:0N from `..currlog where tbl=tab;
 };

/ roll all logs at the end of a logging period
.stplg.rolllog:{[multilog;dir;tabs;p]
  .stpm.updmeta[multilog][`close;tabs;p];
  .stplg.closelog each tabs;
  @[`.stplg.msgcount;tabs;:;0];
  {[m;d;t]
    .[.stplg.openlog;(m;d;t;.stplg.currperiod);
      {.z.m.log[`error][`stp;"failed to open log for table ",string[y],": ",x]}[;t]]
  }[multilog;dir;]each tabs;
  .stpm.updmeta[multilog][`open;tabs;p];
 };

/ process data sent at endofday/endofperiod
.stplg.endofdaydata:@[value;`.stplg.endofdaydata;{ {`proctype`procname`tables!(.z.m.proctype;.z.m.procname;.stpps.t)} }];

/ chained end of period: pass on to subscribers; roll logs in create mode
.stplg.endofperiod:{[currentpd;nextpd;data]
  .z.m.log[`info][`endofperiod;"flushing remaining data to subscribers and clearing tables"];
  .stpps.pubclear[.stplg.t];
  .z.m.log[`info][`endofperiod;"executing end of period for ",.Q.s1 `currentperiod`nextperiod!(currentpd;nextpd)];
  .stpps.endp[currentpd;nextpd;data];
  .stplg.currperiod:nextpd;
  if[.sctp.loggingmode=`create;.stplg.periodrollover[data]]
  };

/ end of period: send to subscribers; roll logs unless end of day is due
.stplg.stpeoperiod:{[currentpd;nextpd;data;rolllogs]
  .z.m.log[`info][`endofperiod;"flushing remaining data to subscribers and clearing tables"];
  .stpps.pubclear[.stplg.t];
  .z.m.log[`info][`stpeoperiod;"passing on endofperiod message to subscribers"];
  .stpps.endp[currentpd;nextpd;data];
  .stplg.currperiod:.stplg.nextperiod;
  if[(data`p)>.stplg.nextperiod:.stplg.multilogperiod+.stplg.currperiod;
    system"t 0";'"next period is in the past"];
  .stplg.getnextendUTC[];
  if[rolllogs;.stplg.periodrollover[data]];
  .z.m.log[`info][`stpeoperiod;"end of period complete, new values for current and next period are ",.Q.s1 (currentpd;nextpd)];
  }

.stplg.periodrollover:{[data]
  .stplg.i+:1;
  .stplg.rolllog[.stplg.multilog;.stplg.dldir;.stplg.rolltabs;data`p];
  }

/ end of day: send to subscribers and roll logs
.stplg.endofday:{[date;data]
  .z.m.log[`info][`endofday;"flushing remaining data to subscribers and clearing tables"];
  .stpps.pubclear[.stplg.t];
  .z.m.log[`info][`endofday;"executing end of day for ",.Q.s1 .z.m.eod.getd[]];
  .stpps.end[date;data];
  .stplg.dayrollover[data];
  }

.stplg.dayrollover:{[data]
  .z.m.eod.setnextroll .z.m.eod.getroll data`p;
  if[(data`p)>.z.m.eod.getnextroll[];
    system"t 0";'"next roll is in the past"];
  .stplg.getnextendUTC[];
  .z.m.eod.setd 1+.z.m.eod.getd[];
  .stpm.updmeta[.stplg.multilog][`close;.stplg.logtabs;(data`p)+.z.m.eod.getdailyadj[]];
  .stpm.metatable:0#.stpm.metatable;
  .stplg.closelog each .stplg.logtabs;
  .stplg.init[string .z.m.procname];
  .z.m.log[`info][`dayrollover;"end of day complete, new value for date is ",.Q.s1 .z.m.eod.getd[]];
  }

.stplg.getnextendUTC:{.stplg.nextendUTC:-1+min(.z.m.eod.getnextroll[];.stplg.nextperiod - .z.m.eod.getdailyadj[])}

.stplg.checkends:{
  if[.stplg.nextendUTC > x; :()];
  if[.stplg.nextperiod < x1:x+.z.m.eod.getdailyadj[]; .stplg.stpeoperiod[.stplg`currperiod;.stplg`nextperiod;.stplg.endofdaydata[],(enlist `p)!enlist x1;not .z.m.eod.getnextroll[] < x]];
  if[.z.m.eod.getnextroll[] < x;if[.z.m.eod.getd[]<("d"$x)-1;system"t 0";'"more than one day?"]; .stplg.endofday[.z.m.eod.getd[];.stplg.endofdaydata[],(enlist `p)!enlist x]];
 };

.stplg.init:{[dbname]
  .stplg.t:tables[`.]except `currlog;
  .stplg.msgcount:.stplg.rowcount:.stplg.t!count[.stplg.t]#0;
  .stplg.tmpmsgcount:.stplg.tmprowcount:(`symbol$())!`long$();
  .stplg.logtabs:$[.stplg.multilog~`custom;key .stplg.custommode;.stplg.t];
  .stplg.rolltabs:$[.stplg.multilog~`custom;.stplg.logtabs except where .stplg.custommode in `tabular`singular;.stplg.t];
  .stplg.currperiod:.stplg.multilogperiod xbar .z.p+.z.m.eod.getdailyadj[];
  .stplg.nextperiod:.stplg.multilogperiod+.stplg.currperiod;
  .stplg.getnextendUTC[];
  .stplg.i:1;
  .stplg.seqnum:0;
  if[(value `..createlogs) or .sctp.loggingmode=`create;
    .stplg.createdld[dbname;.z.m.eod.getd[]];
    .stplg.openlog[.stplg.multilog;.stplg.dldir;;.z.p+.z.m.eod.getdailyadj[]]each .stplg.logtabs;
    if[.stplg.errmode;.stplg.openlogerr[.stplg.dldir]];
    / read the meta table from disk and continue its sequence
    .stpm.metatable:@[get;hsym`$string[.stplg.dldir],"/stpmeta";0#.stpm.metatable];
    .stplg.i:1+ -1|exec max seq from .stpm.metatable;
    .stpm.updmeta[.stplg.multilog][`open;.stplg.logtabs;.z.p+.z.m.eod.getdailyadj[]];
    ]
  / chained and not creating logs: no log handles
  if[.sctp.chainedtp and not .sctp.loggingmode=`create;
    `..loghandles set .stplg.t! (count .stplg.t) # enlist  (::)
   ]
 };
