/ periodic tp logging

\d .

/ live logs and handles to logs for each table
currlog:([tbl:`symbol$()]logname:`symbol$();handle:`int$())

/ view of log file handles for faster lookups
loghandles::exec tbl!handle from currlog

\d .os

if[not `md in key `.os;
  NT:.z.o in`w32`w64;
  Fex:{not 0h~type key hsym$[10=type x;`$x;x]};
  pth:{if[10h<>type x;x:string x]; if[NT;x:@[x;where"/"=x;:;"\\"]];$[":"=first x;1_x;x]};
  md:{if[not Fex x;system"mkdir \"",pth[x],"\""]}];

\d .stplg

/ settings
multilog:`tabperiod                                   / [tabperiod|none|periodic|tabular|custom]
multilogperiod:0D01
errmode:1b
batchmode:`defaultbatch                               / [memorybatch|defaultbatch|immediate]
replayperiod:`day                                     / [period|day|prior]
customcsv:`
kdbtplog:`$getenv`KDBTPLOG

errorlogname:@[value;`.stplg.errorlogname;`segmentederrorlogfile]

/ create log directory `:stplogs/date/tabname_time
createdld:{[name;date]
  if[not count dir:hsym .stplg.kdbtplog;.z.m.log[`error][`stp;"log directory not defined"];exit 1];
  .os.md dir;
  .os.md .stplg.dldir:` sv dir,`$raze/[string name,"_",date];
 };

gentimeformat:{(raze string "dv"$x) except ".:"};

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
upd:@[value;`.stplg.upd;enlist[`]!enlist ()];
zts:@[value;`.stplg.zts;enlist[`]!enlist ()];

/ functions to add columns on updates
updtab:@[value;`.stplg.updtab;enlist[`]!enlist {(enlist(count first x)#y),x}]

/ memorybatch: insert in memory; write, publish and count on the timer
upd[`memorybatch]:{[t;x;now]
  t insert updtab[t] . (x;now);
 };

zts[`memorybatch]:{
  {[t]
    if[count value t;
      `..loghandles[t] enlist (`upd;t;value flip value t);
      @[`.stplg.msgcount;t;+;1];
      @[`.stplg.rowcount;t;+;count value t];
      .stpps.pubclear[t]];
  }each .stpps.t;
 };

/ defaultbatch: write immediately, publish on the timer
upd[`defaultbatch]:{[t;x;now]
  t insert x:.stplg.updtab[t] . (x;now);
  `..loghandles[t] enlist(`upd;t;x);
  @[`.stplg.tmpmsgcount;t;+;1];
  @[`.stplg.tmprowcount;t;+;count first x];
 };

zts[`defaultbatch]:{
  .stpps.pubclear[.stpps.t];
  .stplg.msgcount+:.stplg.tmpmsgcount;
  .stplg.rowcount+:.stplg.tmprowcount;
  .stplg.tmpmsgcount:.stplg.tmprowcount:()!();
 };

/ immediate: write and publish immediately
upd[`immediate]:{[t;x;now]
  x:updtab[t] . (x;now);
  `..loghandles[t] enlist(`upd;t;x);
  x:$[0h>type last x;enlist;flip] .stpps.tabcols[t]!x;
  @[`.stplg.msgcount;t;+;1];
  @[`.stplg.rowcount;t;+;count x];
  .stpps.pub[t;x]
 };

zts[`immediate]:{}

/ logcounts and lognames for client replay
replaylog:{[t]
  getlogs[replayperiod][t]
 }

getlogs:enlist[`]!enlist ()

/ period: logs for the current logging period
getlogs[`period]:{[t]
  distinct flip (.stplg.msgcount;exec tbl!logname from `..currlog where tbl in t)@\:t
 };

/ day: all of today's logs; closed logs count 0W
getlogs[`day]:{[t]
  lnames:select seq,tbls,logname,msgcount:0Wj from .stpm.metatable where any each tbls in\: t;
  lnames:update msgcount:sum each .stplg.msgcount[tbls] from lnames where seq=.stplg.i;
  flip value exec `long$msgcount,logname from lnames
 };

/ open log for a table at the start of a logging period
openlog:{[multilog;dir;tab;p]
  lname:logname[multilog][dir;tab;p];
  .z.m.log[`info][`openlog;"opening logfile: ",string lname];
  h:$[(notexists:not type key lname)or null h0:exec first handle from `..currlog where logname=lname;
    [if[notexists;.[lname;();:;()]];hopen lname];
    h0
  ];
  `..currlog upsert (tab;lname;h);
 };

/ error log for failed updates in error mode
openlogerr:{[dir]
  lname:.[.stplg.logname.error;(dir;.stplg.errorlogname;.z.p+.z.m.eod.getdailyadj[]);{.z.m.log[`error][`openlogerr;"failed to make error log: ",x]}];
  if[not type key lname;.[lname;();:;()]];
  h:@[{hopen x};lname;{.z.m.log[`error][`openlogerr;"failed to open handle to error log with error: ",x]}];
  `..currlog upsert (errorlogname;lname;h);
 };

badmsg:{[e;t;x]
  .z.m.log[`info][`upd;"Bad message received, error: ",e];
  `..loghandles[errorlogname] enlist(`upderr;t;x);
 };

closelog:{[tab]
  if[null h:`..currlog[tab;`handle];.z.m.log[`info][`closelog;"no open handle to log file"];:()];
  .z.m.log[`info][`closelog;"closing log file ",string `..currlog[tab;`logname]];
  @[hclose;h;{.z.m.log[`error][`closelog;"handle already closed"]}];
  update handle:0N from `..currlog where tbl=tab;
 };

/ roll all logs at the end of a logging period
rolllog:{[multilog;dir;tabs;p]
  .stpm.updmeta[multilog][`close;tabs;p];
  closelog each tabs;
  @[`.stplg.msgcount;tabs;:;0];
  {[m;d;t]
    .[openlog;(m;d;t;currperiod);
      {.z.m.log[`error][`stp;"failed to open log for table ",string[y],": ",x]}[;t]]
  }[multilog;dir;]each tabs;
  .stpm.updmeta[multilog][`open;tabs;p];
 };

/ process data sent at endofday/endofperiod
endofdaydata:@[value;`.stplg.endofdaydata;{ {`proctype`procname`tables!(.z.m.proctype;.z.m.procname;.stpps.t)} }];

/ chained end of period: pass on to subscribers; roll logs in create mode
endofperiod:{[currentpd;nextpd;data]
  .z.m.log[`info][`endofperiod;"flushing remaining data to subscribers and clearing tables"];
  .stpps.pubclear[.stplg.t];
  .z.m.log[`info][`endofperiod;"executing end of period for ",.Q.s1 `currentperiod`nextperiod!(currentpd;nextpd)];
  .stpps.endp[currentpd;nextpd;data];
  currperiod::nextpd;
  if[.sctp.loggingmode=`create;periodrollover[data]]
  };

/ end of period: send to subscribers; roll logs unless end of day is due
stpeoperiod:{[currentpd;nextpd;data;rolllogs]
  .z.m.log[`info][`endofperiod;"flushing remaining data to subscribers and clearing tables"];
  .stpps.pubclear[.stplg.t];
  .z.m.log[`info][`stpeoperiod;"passing on endofperiod message to subscribers"];
  .stpps.endp[currentpd;nextpd;data];
  currperiod::nextperiod;
  if[(data`p)>nextperiod::multilogperiod+currperiod;
    system"t 0";'"next period is in the past"];
  getnextendUTC[];
  if[rolllogs;periodrollover[data]];
  .z.m.log[`info][`stpeoperiod;"end of period complete, new values for current and next period are ",.Q.s1 (currentpd;nextpd)];
  }

periodrollover:{[data]
  i+::1;
  rolllog[multilog;dldir;rolltabs;data`p];
  }

/ end of day: send to subscribers and roll logs
endofday:{[date;data]
  .z.m.log[`info][`endofday;"flushing remaining data to subscribers and clearing tables"];
  .stpps.pubclear[.stplg.t];
  .z.m.log[`info][`endofday;"executing end of day for ",.Q.s1 .z.m.eod.getd[]];
  .stpps.end[date;data];
  dayrollover[data];
  }

dayrollover:{[data]
  .z.m.eod.setnextroll .z.m.eod.getroll data`p;
  if[(data`p)>.z.m.eod.getnextroll[];
    system"t 0";'"next roll is in the past"];
  getnextendUTC[];
  .z.m.eod.setd 1+.z.m.eod.getd[];
  .stpm.updmeta[multilog][`close;logtabs;(data`p)+.z.m.eod.getdailyadj[]];
  .stpm.metatable:0#.stpm.metatable;
  closelog each logtabs;
  init[string .z.m.procname];
  .z.m.log[`info][`dayrollover;"end of day complete, new value for date is ",.Q.s1 .z.m.eod.getd[]];
  }

getnextendUTC:{nextendUTC::-1+min(.z.m.eod.getnextroll[];nextperiod - .z.m.eod.getdailyadj[])}

checkends:{
  if[nextendUTC > x; :()];
  if[nextperiod < x1:x+.z.m.eod.getdailyadj[]; stpeoperiod[.stplg`currperiod;.stplg`nextperiod;.stplg.endofdaydata[],(enlist `p)!enlist x1;not .z.m.eod.getnextroll[] < x]];
  if[.z.m.eod.getnextroll[] < x;if[.z.m.eod.getd[]<("d"$x)-1;system"t 0";'"more than one day?"]; endofday[.z.m.eod.getd[];.stplg.endofdaydata[],(enlist `p)!enlist x]];
 };

init:{[dbname]
  t::tables[`.]except `currlog;
  msgcount::rowcount::t!count[t]#0;
  tmpmsgcount::tmprowcount::(`symbol$())!`long$();
  logtabs::$[multilog~`custom;key custommode;t];
  rolltabs::$[multilog~`custom;logtabs except where custommode in `tabular`singular;t];
  currperiod::multilogperiod xbar .z.p+.z.m.eod.getdailyadj[];
  nextperiod::multilogperiod+currperiod;
  getnextendUTC[];
  i::1;
  seqnum::0;
  if[(value `..createlogs) or .sctp.loggingmode=`create;
    createdld[dbname;.z.m.eod.getd[]];
    openlog[multilog;dldir;;.z.p+.z.m.eod.getdailyadj[]]each logtabs;
    if[.stplg.errmode;openlogerr[dldir]];
    / read the meta table from disk and continue its sequence
    .stpm.metatable:@[get;hsym`$string[.stplg.dldir],"/stpmeta";0#.stpm.metatable];
    i::1+ -1|exec max seq from .stpm.metatable;
    .stpm.updmeta[multilog][`open;logtabs;.z.p+.z.m.eod.getdailyadj[]];
    ]
  / chained and not creating logs: no log handles
  if[.sctp.chainedtp and not .sctp.loggingmode=`create;
    `..loghandles set t! (count t) # enlist  (::)
   ]
 };

\d .
