/ di.torq.proc.segmentedtp - segmented tickerplant. Receives feed updates, timestamps them, writes them to one of
/ five log layouts (per table or shared, rolled per period or per day, or a per-table custom mix), publishes them
/ via di.pubsub in one of three batch modes, and rolls its logs at end of period and end of day.
/ Built from TorQ/code/processes/segmentedtickerplant.q and code/segmentedtickerplant/{stplog,stpmeta,pubsub}.q,
/ standalone configuration only (the chained sctp.q variant is out of scope). Hard deps: di.pubsub (sub/pub),
/ di.eodtime (roll timing), di.tplogmgr (write only - naming, open and roll are self-implemented because
/ di.tplogmgr is fixed at one file per date). Injected deps: log, timer, handlers. Design record: segmentedtp.md.

/ --- constants ---

modes:`tabperiod`singular`periodic`tabular`custom;
custommodes:`tabperiod`singular`periodic`tabular;
batchmodes:`memorybatch`defaultbatch`immediate;
replayperiods:`period`day;
jobid:`segmentedtp;                                      / the timer job and .z.exit handler name
copychunk:8388608;                                       / bytes per read when copying a corrupt log's good prefix

/ live log per table: the file it writes to and the handle (shared by every table writing that file)
currlogschema:([tbl:`symbol$()]logname:`symbol$();handle:`int$());

/ on-disk metatable, one row per physical log file (TorQ's stpmeta.q)
metaschema:([]seq:`int$();logname:`symbol$();start:`timestamp$();end:`timestamp$();tbls:();msgcount:`int$();schema:();additional:());

/ --- module state read before init has run (everything else is written by init) ---

initdone:0b;
logwired:0b;
currlog:currlogschema;
errh:0Ni;

/ --- shared helpers (as di.torq.proc.tickerplant) ---

/ base dirs: CODE/CONFIG under TORQXAPPHOME, runtime DATA under TORQXDATAHOME (falling back to TORQXAPPHOME)
apphome:{getenv[`TORQXAPPHOME]};
datahome:{$[count h:getenv[`TORQXDATAHOME];h;getenv[`TORQXAPPHOME]]};

/ resolve a possibly-relative dir setting to an absolute path STRING under base; symbol (.q) or string (.toml) input
resolvedir:{[base;dir]
  dir:$[10h=abs type dir;dir;string dir];
  dir:$[(0<count dir) and ":"=first dir;1_dir;dir];
  $[dir like "/*";dir;base,"/",dir]
  };

/ config values may be symbols (.q settings), strings (.toml, command-line overrides) or numbers; coerce at the
/ point of use. a string reaching `boolean$ would give a boolean LIST, which throws 'type in if/$ on every update,
/ and "j"$"5" is the character code 53 - so strings are parsed, not cast
/ (a one-character string is a char atom in q, hence the abs types and the (),x)
astz:{[x] $[11h=abs type x;x;`$(),x]};
tostr:{[x] $[10h=abs type x;(),x;string x]};
tobool:{[x] $[-1h=type x;x;10h=abs type x;(lower (),x) in ("true";"1";"t";"y";"yes");`boolean$x]};
tolong:{[x] $[10h=abs type x;"J"$(),x;"j"$x]};
/ a timespan, a "0D01:00:00" string, or a number of SECONDS (TOML has no timespan type)
totimespan:{[x] $[-16h=type x;x;10h=abs type x;"N"$(),x;-11h=type x;"N"$string x;type[x] in -5 -6 -7h;0D00:00:01*x;0Nn]};
cfgor:{[config;k;dflt] $[k in key config;config k;dflt]};

/ feed payloads may arrive as a table or as a list of columns; normalise to columns
tocols:{[x] $[98h=type x;value flip x;x]};

raiseerror:{[ctx;msg]
  / log (once a logger is wired) then signal, so failures are observable as well as thrown
  if[.z.m.logwired;.z.m.log[`error][ctx;msg]];
  '"di.torq.proc.segmentedtp: ",(string ctx),": ",msg;
  };

requireinit:{[ctx]
  if[not .z.m.initdone;raiseerror[ctx;"init must be called before any other function"]];
  };

/ --- log naming (TorQ's .stplg.logname) ---

/ timestamp string used in log names, e.g. 20260914130000
gentimeformat:{[p] (raze string "dv"$p) except ".:"};

lognametabperiod:{[dir;tab;p] hsym `$dir,"/",.z.m.logprefix,"_",(string tab),gentimeformat p};
lognamesingular:{[dir;tab;p] hsym `$dir,"/",.z.m.logprefix,"_",gentimeformat p};
lognameperiodic:{[dir;tab;p] hsym `$dir,"/",.z.m.logprefix,"_periodic",gentimeformat p};
lognametabular:{[dir;tab;p] hsym `$dir,"/",.z.m.logprefix,"_",(string tab),gentimeformat p};
lognameerror:{[dir;ename;p] hsym `$dir,"/",.z.m.logprefix,"_",(string ename),gentimeformat p};

lognames:`tabperiod`singular`periodic`tabular!(lognametabperiod;lognamesingular;lognameperiodic;lognametabular);

lognamefor:{[tab;p]
  / the log a table writes to for the period starting p, under its custom assignment or the top-level mode
  m:$[.z.m.multilog=`custom;.z.m.custommode tab;.z.m.multilog];
  lognames[m][.z.m.dldir;tab;p]
  };

/ --- log files ---

goodname:{[ln] `$(string ln),".good"};

/ a log recovered on an earlier start lives on as <name>.good - keep using it rather than the corrupt original
resolvelog:{[ln] $[type key g:goodname ln;g;ln]};

openfile:{[ln]
  / hopen a log, creating it if absent. an existing log is counted first WITHOUT executing it, and a corrupt one
  / is never opened blind (TorQ's openlog did) - its good prefix is copied to <name>.good and that is opened.
  / the message count found is kept as the file's base count. returns (name;handle)
  if[not type key ln;.[ln;();:;()]];
  / a zero-byte file (a crash between create and header write) is safely re-headed; a file shorter than the 8-byte
  / header, or one -11!(-2;..) cannot read at all, holds no recoverable message - recover it as an empty log
  if[0=hcount ln;.[ln;();:;()]];
  info:@[-11!;(-2;ln);{0 0}];
  if[1<count info;ln:recoverlog[ln;info];info:first info];
  .z.m.basecount[ln]:info;
  (ln;hopen ln)
  };

recoverlog:{[ln;info]
  / copy the good prefix (info 1 bytes, info 0 messages) of a corrupt log aside and return its name. a generic byte
  / copy, not di.tplog.repair - that only recovers `trade messages and would silently empty any other table's log.
  / the corrupt original is left untouched; the copy is written via a temp file so a .good can itself be recovered.
  / a prefix shorter than a log header is no log at all - the copy is a fresh empty log instead
  g:$[ln like "*.good";ln;goodname ln];
  tmp:`$(string g),".tmp";
  $[8>info 1;.[tmp;();:;()];copyprefix[ln;tmp;info 1]];
  system "mv -f ",(shq 1_string tmp)," ",shq 1_string g;
  renamemeta[ln;g];
  .z.m.log[`warn][`openlog;"corrupt log ",(1_string ln),": kept ",(string info 0)," good message(s) (",(string info 1)," bytes) in ",1_string g];
  g
  };

copyprefix:{[src;dst;n]
  / copy the first n bytes of src to dst in bounded chunks; the destination handle is closed even if a read fails
  dst 1: `byte$();
  h:hopen dst;
  r:@[{[src;h;n] copychunkto[src;h;n]/[0j]}[src;h];n;{[e] (`copyfailed;e)}];
  hclose h;
  if[`copyfailed~first r;'"copying ",(1_string src),": ",r 1];
  };

/ shell-quote a path for system calls (mkdir / mv)
shq:{[p] "\"",p,"\""};

copychunkto:{[src;h;n;o]
  / append the next chunk of src from offset o; returns the new offset, unchanged once at n (ending the over)
  if[o>=n;:o];
  k:copychunk&n-o;
  h read1 (src;o;k);
  o+k
  };

rebuildhandles:{[] .z.m.loghandles:exec tbl!handle from .z.m.currlog;};

openlog:{[tab;p]
  / open - or share, when another table already has it open - the log tab writes to for the period starting p
  ln:resolvelog lognamefor[tab;p];
  h:exec first handle from .z.m.currlog where logname=ln,not null handle;
  if[null h;r:openfile ln;ln:r 0;h:r 1];
  .z.m.currlog:.z.m.currlog upsert (tab;ln;h);
  rebuildhandles[];
  .z.m.log[`info][`openlog;"table ",(string tab)," logging to ",1_string ln];
  };

openfail:{[tab;e] .z.m.log[`error][`rolllog;"failed to open log for table ",(string tab),": ",e];};

openlogsafe:{[tab;p] .[openlog;(tab;p);openfail[tab]];};

closefail:{[h;e] .z.m.log[`warn][`closelog;"handle ",(string h)," already closed: ",e];};

closehandle:{[h] @[hclose;h;closefail[h]];};

closelogs:{[ts]
  / close the files the given tables write to - a shared file is closed once, and only when no other table uses it
  hs:distinct exec handle from .z.m.currlog where tbl in ts,not null handle;
  hs:hs except exec handle from .z.m.currlog where not tbl in ts,not null handle;
  closehandle each hs;
  .z.m.currlog:update handle:0Ni from .z.m.currlog where tbl in ts;
  rebuildhandles[];
  if[count hs;.z.m.log[`info][`closelog;"closed ",(string count hs)," log file(s)"]];
  };

openerrlog:{[]
  / the day's error log for messages that fail in errmode - one per day, so a restart appends to it
  d:(.z.m.eod`getd)[];
  r:openfile resolvelog lognameerror[.z.m.dldir;.z.m.errorlogname;"p"$d];
  .z.m.errlog:r 0;
  .z.m.errh:r 1;
  .z.m.log[`info][`openerrlog;"error log is ",1_string .z.m.errlog];
  };

closeerrlog:{[]
  / the error log is tracked apart from currlog, so every roll and shutdown must close it explicitly - TorQ's
  / dayrollover never did, leaking one handle per day
  if[null .z.m.errh;:()];
  closehandle .z.m.errh;
  .z.m.errh:0Ni;
  .z.m.log[`info][`closeerrlog;"closed error log ",1_string .z.m.errlog];
  };

releaselogs:{[]
  / close whatever an earlier init left open, without touching the metatable - used when init is called again
  closehandle each distinct exec handle from .z.m.currlog where not null handle;
  .z.m.currlog:currlogschema;
  if[not null .z.m.errh;closehandle .z.m.errh];
  .z.m.errh:0Ni;
  rebuildhandles[];
  };

writelog:{[t;msg]
  / append to the table's log. tables with no open log (createlogs off, or unlisted in custom mode) are skipped -
  / TorQ applied the null handle and threw on every update
  if[not null h:.z.m.loghandles t;(.z.m.tp`write)[h;msg]];
  };

/ --- metatable (TorQ's stpmeta.q) ---

filecount:{[ln]
  / messages in a physical file: its count when opened plus what every table sharing it has written since
  ts:exec tbl from .z.m.currlog where logname=ln;
  (0^.z.m.basecount ln)+sum .z.m.msgcount ts
  };

addmetarow:{[row] .z.m.metatable:.z.m.metatable,enlist row;};

renamemeta:{[ln;g] .z.m.metatable:update logname:g from .z.m.metatable where logname=ln;};

metaopen:{[p;ln;ts]
  / a file already in the metatable (a restart or reassignment resuming the same segment) is reopened, not repeated
  if[ln in .z.m.metatable`logname;
    .z.m.metatable:update end:0Np,tbls:{distinct x,y}[;ts] each tbls from .z.m.metatable where logname=ln;
    :()];
  addmetarow `seq`logname`start`end`tbls`msgcount`schema`additional!(.z.m.seq;ln;p;0Np;ts;0i;ts#.z.m.schemas;()!());
  };

metaclose:{[p;ln]
  / stamp a segment closed with the messages its file holds
  c:"i"$filecount ln;
  .z.m.metatable:update end:p,msgcount:c from .z.m.metatable where logname=ln,null end;
  };

updmeta:{[ev;ts;p]
  / record segments opening or closing. grouped by PHYSICAL file, so a shared singular/periodic file gets one row and a
  / per-table file one row whatever mode assigned it - TorQ's custom path wrote custom singular tables per table
  if[not count ts;:()];
  grp:exec tbl by logname from .z.m.currlog where tbl in ts,not null logname;
  if[count grp;$[ev=`open;metaopen[p]'[key grp;value grp];metaclose[p] each key grp]];
  setmeta[];
  };

setmetafail:{[e] .z.m.log[`error][`setmeta;"failed to persist the metatable: ",e];};

setmeta:{[] .[set;(hsym`$.z.m.dldir,"/stpmeta";.z.m.metatable);setmetafail];};

loadmetafail:{[e]
  .z.m.log[`warn][`loadmeta;"unreadable metatable, starting a new one: ",e];
  :metaschema;
  };

loadmeta:{[]
  f:hsym`$.z.m.dldir,"/stpmeta";
  $[type key f;@[get;f;loadmetafail];metaschema]
  };

reconcilemeta:{[]
  / TorQ appended a row on every open, so an unclean exit left a never-closed row behind. a still-open row for a file
  / opened again now is resumed; any other still-open row is an orphan - closed with an unknown (null) message count,
  / not a count guessed by replaying the file, which would drive the root upd
  cur:exec distinct logname from .z.m.currlog where not null logname;
  stale:exec logname from .z.m.metatable where null end,not logname in cur;
  now:.z.p+(.z.m.eod`getdailyadj)[];
  if[count stale;
    .z.m.metatable:update end:now,msgcount:0Ni from .z.m.metatable where logname in stale;
    .z.m.log[`warn][`reconcilemeta;"closed ",(string count stale)," segment(s) left open by an unclean shutdown: ",", " sv 1_'string stale]];
  resumed:exec seq from .z.m.metatable where logname in cur;
  .z.m.seq:$[count resumed;max resumed;1i+-1i|max .z.m.metatable`seq];
  };

/ --- replay lists for subscribers: (message count;log file) pairs, as -11! takes them ---

getlogsperiod:{[ts]
  / the current period only: one pair per physical file, counting every table in it - not one pair per table,
  / which double-counts a shared singular/periodic file
  lns:exec distinct logname from .z.m.currlog where tbl in ts,not null handle;
  flip (filecount each lns;lns)
  };

getlogsday:{[ts]
  / the whole day from the metatable: closed segments replay in full (0W), open ones up to their current count
  m:select logname,end from .z.m.metatable where any each tbls in\: ts;
  if[not count m;:()];
  flip (?[null m`end;filecount each m`logname;0W];m`logname)
  };

getlogsfns:`period`day!(getlogsperiod;getlogsday);

/ --- updates and the three batch modes (TorQ's .stplg.upd / .stplg.zts) ---

stampcols:{[x;ts]
  / prepend the arrival timestamp, unless the first column already is one (as di.torq.proc.tickerplant)
  if[-12h=type first first x;:x];
  $[0>type first x;ts,x;(enlist(count first x)#ts),x]
  };

updmemory:{[t;x;ts]
  / memorybatch: buffer only - logging and publishing both wait for the flush
  t insert stampcols[tocols x;ts];
  };

flushtable:{[t]
  / memorybatch flush for one table: the whole buffer goes to the log as ONE message, then is published and cleared
  if[not n:count value t;:()];
  writelog[t;(`upd;t;value flip value t)];
  .z.m.msgcount[t]+:1;
  .z.m.rowcount[t]+:n;
  (.z.m.ps`pubclear)[t];
  };

flushmemory:{[] flushtable each .z.m.pubtabs;};

upddefault:{[t;x;ts]
  / defaultbatch: log straight away, publish on the flush. counts are held as pending until published, so a
  / subscriber's replay count never includes a message it will also receive live
  x:stampcols[tocols x;ts];
  t insert x;
  writelog[t;(`upd;t;x)];
  .z.m.tmpmsgcount[t]+:1;
  .z.m.tmprowcount[t]+:count first x;
  };

resettmp:{[]
  .z.m.tmpmsgcount:.z.m.pubtabs!count[.z.m.pubtabs]#0j;
  .z.m.tmprowcount:.z.m.pubtabs!count[.z.m.pubtabs]#0j;
  };

flushdefault:{[]
  (.z.m.ps`pubclear)[.z.m.pubtabs];
  .z.m.msgcount+:.z.m.tmpmsgcount;
  .z.m.rowcount+:.z.m.tmprowcount;
  resettmp[];
  };

updimmediate:{[t;x;ts]
  / immediate: log and publish on every update
  x:stampcols[tocols x;ts];
  writelog[t;(`upd;t;x)];
  d:flip .z.m.tabcols[t]!$[0>type first x;enlist each x;x];
  .z.m.msgcount[t]+:1;
  .z.m.rowcount[t]+:count d;
  (.z.m.ps`publish)[t;d];
  };

flushimmediate:{[]};

updfns:`memorybatch`defaultbatch`immediate!(updmemory;upddefault;updimmediate);
flushfns:`memorybatch`defaultbatch`immediate!(flushmemory;flushdefault;flushimmediate);

unknowntable:{[t;x;ts] raiseerror[`upd;"not a publishable table: ",-3!t]};

badmsg:{[t;x;e]
  / errmode: log the failure, then keep the message in the error log as (`upderr;t;x)
  .z.m.log[`warn][`upd;"bad message for ",(-3!t),": ",e];
  if[not null .z.m.errh;(.z.m.tp`write)[.z.m.errh;(`upderr;t;x)]];
  };

updmsg:{[t;x;ts]
  / one table's message; in errmode a failure goes to the error log instead of back to the feed
  f:$[t in .z.m.pubtabs;.z.m.updfn;unknowntable];
  $[.z.m.errmode;.[f;(t;x;ts);badmsg[t;x]];f[t;x;ts]];
  };

rollfail:{[e] .z.m.log[`error][`upd;"end of period/day check failed: ",e];};

upd:{[t;x]
  / feed entry point (root upd / .u.upd): check for a period or day end, then log and publish under the batch mode.
  / a failed roll is logged and stops the tick job, but does not lose the message that exposed it
  requireinit`upd;
  / a string table name would be iterated character by character below
  if[10h=type t;t:`$t];
  now:.z.p;
  if[.z.m.nextendutc<now;@[checkends;now;rollfail]];
  ts:now+(.z.m.eod`getdailyadj)[];
  $[0h<type t;updmsg'[t;x;ts];updmsg[t;x;ts]];
  .z.m.seqnum+:1;
  };

/ --- period and day ends ---

getnextendutc:{[] .z.m.nextendutc:-1+min((.z.m.eod`getnextroll)[];.z.m.nextperiod-(.z.m.eod`getdailyadj)[]);};

enddata:{[p] `proctype`procname`tables`p!(.z.m.proctype;.z.m.procname;.z.m.pubtabs;p)};

stopjob:{[ctx;msg]
  / TorQ turned off the WHOLE process timer (system"t 0") here; stop only this module's job - the next good roll
  / re-enables it
  (.z.m.timer`disablejobs)[enlist jobid];
  raiseerror[ctx;msg];
  };

rolllog:{[ts;p]
  / period roll for the given tables: close their segments, reopen at the new period
  updmeta[`close;ts;p];
  closelogs ts;
  .z.m.msgcount:@[.z.m.msgcount;ts;:;0j];
  openlogsafe[;.z.m.currperiod] each ts;
  updmeta[`open;ts;p];
  };

endofperiod:{[currentpd;nextpd;data;rolllogs]
  / flush (so a memorybatch buffer is logged into the period it arrived in), tell subscribers, advance, roll.
  / di.pubsub.callendofperiod is monadic, so subscribers receive the (current;next;data) triple as one argument
  .z.m.flushfn[];
  (.z.m.ps`callendofperiod)[(currentpd;nextpd;data)];
  .z.m.currperiod:nextpd;
  .z.m.nextperiod:.z.m.multilogperiod+nextpd;
  if[(data`p)>.z.m.nextperiod;stopjob[`endofperiod;"next period is in the past"]];
  getnextendutc[];
  if[rolllogs and .z.m.createlogs;.z.m.seq+:1i;rolllog[.z.m.rolltabs;data`p]];
  (.z.m.timer`enablejobs)[enlist jobid];
  .z.m.log[`info][`endofperiod;"end of period complete, current period is now ",string .z.m.currperiod];
  };

closeday:{[p]
  / close every open segment and file, the error log included
  if[.z.m.createlogs;updmeta[`close;exec tbl from .z.m.currlog;p];closelogs exec tbl from .z.m.currlog];
  closeerrlog[];
  };

dayrollover:{[data]
  nr:(.z.m.eod`getroll)[data`p];
  (.z.m.eod`setnextroll)[nr];
  if[(data`p)>nr;stopjob[`endofday;"next roll is in the past"]];
  (.z.m.eod`setd)[1+(.z.m.eod`getd)[]];
  closeday (data`p)+(.z.m.eod`getdailyadj)[];
  (.z.m.eod`setdailyadj)[(.z.m.eod`getdailyadjustment)[]];
  startday[];
  (.z.m.timer`enablejobs)[enlist jobid];
  .z.m.log[`info][`endofday;"end of day complete, date is now ",string (.z.m.eod`getd)[]];
  };

endofday:{[d;data]
  / flush, tell subscribers, roll every log into the next day's directory
  .z.m.flushfn[];
  (.z.m.ps`callendofday)[d];
  dayrollover data;
  };

dayend:{[now]
  if[(.z.m.eod`getd)[]<("d"$now)-1;stopjob[`checkends;"more than one day has passed since the last end of day"]];
  endofday[(.z.m.eod`getd)[];enddata now];
  };

checkends:{[now]
  / fire end of period and/or end of day once a boundary has passed
  if[.z.m.nextendutc>now;:()];
  adj:now+(.z.m.eod`getdailyadj)[];
  if[.z.m.nextperiod<adj;endofperiod[.z.m.currperiod;.z.m.nextperiod;enddata adj;not (.z.m.eod`getnextroll)[]<now]];
  if[(.z.m.eod`getnextroll)[]<now;dayend now];
  };

tickbody:{[]
  .z.m.flushfn[];
  checkends .z.p;
  };

tickfail:{[e] .z.m.log[`error][`tick;"flush or end-of-period/day check failed: ",e];};

tick:{[]
  / timer job, every tickinterval seconds: flush the batch, then check for a period or day end. protected and logged
  / here - di.timer swallows a job's error unless its debug flag is on, and with disableonfail (its default) one
  / transient failure would silently stop this process flushing and rolling for good. the job is registered with
  / disableonfail off for the same reason; a guard trip still stops it explicitly via stopjob
  @[tickbody;::;tickfail];
  };

/ the tick job's di.timer options: survive a failing run (see tick)
jobopts:enlist[`disableonfail]!enlist 0b;

/ --- day start ---

resetcounts:{[]
  .z.m.msgcount:.z.m.pubtabs!count[.z.m.pubtabs]#0j;
  .z.m.rowcount:.z.m.pubtabs!count[.z.m.pubtabs]#0j;
  resettmp[];
  };

settabsets:{[]
  / tables with a log, and tables rolled at period end (custom singular/tabular tables roll daily only)
  .z.m.logtabs:$[.z.m.multilog=`custom;.z.m.pubtabs inter key .z.m.custommode;.z.m.pubtabs];
  .z.m.rolltabs:$[.z.m.multilog=`custom;.z.m.logtabs except where .z.m.custommode in `tabular`singular;.z.m.pubtabs];
  };

openday:{[]
  / open today's directory and logs, reconcile the metatable against what was actually opened, record the segments.
  / logs open at the start of the current period, so a restart within a period resumes the same files
  d:(.z.m.eod`getd)[];
  .z.m.dldir:.z.m.kdbtplog,"/",.z.m.logprefix,"_",string d;
  system "mkdir -p ",shq .z.m.dldir;
  .z.m.metatable:loadmeta[];
  openlog[;.z.m.currperiod] each .z.m.logtabs;
  if[.z.m.errmode;openerrlog[]];
  reconcilemeta[];
  updmeta[`open;.z.m.logtabs;.z.p+(.z.m.eod`getdailyadj)[]];
  .z.m.log[`info][`openday;"opened ",(string count exec distinct logname from .z.m.currlog)," log file(s) in ",.z.m.dldir];
  };

startday:{[]
  / reset the per-day state and, when logging, open the day's logs (TorQ's .stplg.init)
  resetcounts[];
  settabsets[];
  .z.m.currperiod:.z.m.multilogperiod xbar .z.p+(.z.m.eod`getdailyadj)[];
  .z.m.nextperiod:.z.m.multilogperiod+.z.m.currperiod;
  getnextendutc[];
  .z.m.currlog:currlogschema;
  .z.m.basecount:(`symbol$())!`long$();
  .z.m.metatable:metaschema;
  .z.m.seq:0i;
  rebuildhandles[];
  if[.z.m.createlogs;openday[]];
  };

/ --- custom mode ---

checkcustommodes:{[ctx;cm]
  if[not 99h=type cm;raiseerror[ctx;"custom modes must be a table!mode dict of symbols"]];
  if[not all 11h=type each (key cm;value cm);raiseerror[ctx;"custom modes must be a table!mode dict of symbols"]];
  if[count bad:where not cm in custommodes;
    raiseerror[ctx;"unrecognised mode for ",(", " sv string bad),"; must be one of ",", " sv string custommodes]];
  };

checkcustomtabs:{[ctx;cm]
  if[count bad:key[cm] except .z.m.pubtabs;raiseerror[ctx;"not publishable tables: ",", " sv string bad]];
  };

readcsvfail:{[e] raiseerror[`readcustomcsv;"failed to read custom mode csv: ",e]};

readcustomcsv:{[path]
  / read a table,mode csv (TorQ's stpcustom.csv) into the table!mode dict setcustommode takes. touches no state
  f:hsym $[10h=type path;`$path;path];
  if[not type key f;raiseerror[`readcustomcsv;"custom mode csv not found: ",1_string f]];
  t:@[("SS";enlist",") 0:;f;readcsvfail];
  if[not `table`mode~cols t;raiseerror[`readcustomcsv;"custom mode csv must have a table,mode header"]];
  cm:exec table!mode from t;
  checkcustommodes[`readcustomcsv;cm];
  cm
  };

loadcustom:{[config]
  / custom assignments come from the customcsv setting; without one nothing is logged until setcustommode is called
  if[not `customcsv in key config;
    .z.m.custommode:(`symbol$())!`symbol$();
    .z.m.log[`warn][`init;"multilog is custom but no customcsv is configured - no table is logged until setcustommode"];
    :()];
  cm:readcustomcsv resolvedir[apphome[];config`customcsv];
  checkcustomtabs[`init;cm];
  .z.m.custommode:cm;
  };

setcustommode:{[cm]
  / replace the custom assignment at runtime: flush, close the open segments, reopen under the new layout
  requireinit`setcustommode;
  if[not .z.m.multilog=`custom;raiseerror[`setcustommode;"multilog is ",(string .z.m.multilog),", not custom"]];
  checkcustommodes[`setcustommode;cm];
  checkcustomtabs[`setcustommode;cm];
  .z.m.flushfn[];
  now:.z.p+(.z.m.eod`getdailyadj)[];
  if[.z.m.createlogs;updmeta[`close;exec tbl from .z.m.currlog;now];closelogs exec tbl from .z.m.currlog];
  .z.m.custommode:cm;
  settabsets[];
  .z.m.currlog:select from .z.m.currlog where tbl in .z.m.logtabs;
  .z.m.msgcount:@[.z.m.msgcount;.z.m.pubtabs;:;0j];
  rebuildhandles[];
  if[.z.m.createlogs;.z.m.seq+:1i;openlog[;.z.m.currperiod] each .z.m.logtabs;updmeta[`open;.z.m.logtabs;now]];
  .z.m.log[`info][`setcustommode;"custom modes set for ",(string count cm)," table(s)"];
  };

/ --- subscriber surface ---

tablelist:{[]
  / TorQ .sub.subscribe's tablesfunc for a segmented tickerplant: the publishable tables
  requireinit`tablelist;
  .z.m.pubtabs
  };

subdetails:{[tabs;instruments]
  / TorQ .sub.subscribe's subfunc for a segmented tickerplant: register the caller with di.pubsub and return, in one
  / synchronous call, what it needs to define and replay the subscribed tables
  requireinit`subdetails;
  r:(.z.m.ps`subscribe)[tabs;instruments];
  if[-11h=type r;raiseerror[`subdetails;string r]];
  if[-11h=type first r;.z.m.log[`warn][`subdetails;string first r];r:last r];
  st:r 0;
  `schemalist`logfilelist`rowcounts`date`logdir!(flip r;.z.m.getlogsfn st;st#.z.m.rowcount;(.z.m.eod`getd)[];`$.z.m.kdbtplog)
  };

/ .u.sub, as TorQ's segmented tickerplant published it
sub:{[tabs;syms] (.z.m.ps`subscribe)[tabs;syms]};

getcounts:{[]
  / message and row counts per table: counted (logged and published) and pending (in the unflushed batch)
  requireinit`getcounts;
  t:.z.m.pubtabs;
  ct:([tbl:t]msgcount:.z.m.msgcount t;rowcount:.z.m.rowcount t;pendingmsgcount:.z.m.tmpmsgcount t;pendingrowcount:.z.m.tmprowcount t);
  `seqnum`tables!(.z.m.seqnum;ct)
  };

/ --- lifecycle ---

exithandler:{[code]
  / .z.exit (via di.torq.handlers): on a clean exit flush a memorybatch buffer and close every segment and file
  if[not 0=code;.z.m.log[`error][`exit;"exit code ",(string code)," - log files left as they are"];:()];
  .z.m.log[`info][`exit;"closing log files"];
  if[.z.m.batchmode=`memorybatch;.z.m.flushfn[]];
  closeday .z.p+(.z.m.eod`getdailyadj)[];
  };

teardown:{[]
  / stop the module: flush, close every segment and file, remove the tick job and the .z.exit and .z.pc handlers
  requireinit`teardown;
  .z.m.flushfn[];
  closeday .z.p+(.z.m.eod`getdailyadj)[];
  (.z.m.timer`deletejobs)[enlist jobid];
  (.z.m.handlers`remove)[`.z.exit;`;jobid];
  (.z.m.handlers`remove)[`.z.pc;`;`pubsub];
  .z.m.initdone:0b;
  .z.m.log[`info][`teardown;"stopped"];
  };

checkdep:{[deps;k;fns;hint]
  if[not k in key deps;'"di.torq.proc.segmentedtp: ",(string k)," dependency is required - ",hint];
  if[99h<>type deps k;'"di.torq.proc.segmentedtp: ",(string k)," dependency must be a dict - ",hint];
  if[count missing:fns except key deps k;'"di.torq.proc.segmentedtp: ",(string k)," dependency is missing ",", " sv string missing];
  };

checkdeps:{[deps]
  / validate the injected deps before anything is wired - plain signals, as no logger is usable yet
  if[99h<>type deps;'"di.torq.proc.segmentedtp: deps must be a dict with `log`timer`handlers keys"];
  checkdep[deps;`log;`info`warn`error;"see di.util.log"];
  checkdep[deps;`timer;`addjob`deletejobs`enablejobs`disablejobs;"see di.timer"];
  checkdep[deps;`handlers;`register`remove;"see di.torq.handlers"];
  };

checkin:{[k;v;ok]
  if[not v in ok;raiseerror[`init;(string k)," must be one of ",(", " sv string ok),"; got ",-3!v]];
  };

readconfig:{[config]
  / read and validate every setting up front: a value used later as a dispatch key would otherwise index to null
  / and fail somewhere unrelated - or, for replayperiod, not fail at all and corrupt subdetails
  .z.m.cfg:config;
  if[not `kdbtplog in key config;raiseerror[`init;"kdbtplog is required - the root directory for the log files"]];
  if[0=count tostr config`kdbtplog;raiseerror[`init;"kdbtplog must name a directory"]];
  .z.m.kdbtplog:resolvedir[datahome[];config`kdbtplog];
  .z.m.multilog:astz cfgor[config;`multilog;`tabperiod];
  .z.m.multilogperiod:totimespan cfgor[config;`multilogperiod;0D01];
  .z.m.errmode:tobool cfgor[config;`errmode;1b];
  .z.m.batchmode:astz cfgor[config;`batchmode;`defaultbatch];
  .z.m.replayperiod:astz cfgor[config;`replayperiod;`day];
  .z.m.errorlogname:astz cfgor[config;`errorlogname;`segmentederrorlogfile];
  .z.m.createlogs:tobool cfgor[config;`createlogs;1b];
  / file and directory names carry the process name, as TorQ's .proc.procname did: two segmented tickerplants
  / sharing a kdbtplog then cannot write the same files or clobber each other's metatable. "stp" only when no
  / procname is known (di.torq always stamps one)
  .z.m.logprefix:tostr cfgor[config;`logprefix;$[`procname in key config;config`procname;"stp"]];
  if[0=count .z.m.logprefix;raiseerror[`init;"logprefix must not be empty"]];
  .z.m.tickinterval:tolong cfgor[config;`tickinterval;1];
  .z.m.proctype:astz cfgor[config;`proctype;`segmentedtp];
  .z.m.procname:astz cfgor[config;`procname;`];
  checkin[`multilog;.z.m.multilog;modes];
  checkin[`batchmode;.z.m.batchmode;batchmodes];
  checkin[`replayperiod;.z.m.replayperiod;replayperiods];
  if[not 0D<.z.m.multilogperiod;raiseerror[`init;"multilogperiod must be a positive timespan"]];
  if[not 0<.z.m.tickinterval;raiseerror[`init;"tickinterval must be a positive number of seconds"]];
  / TorQ's system"t 1000" was milliseconds; di.timer's period is seconds, so a carried-over 1000 is ~16 minutes
  if[60<=.z.m.tickinterval;
    .z.m.log[`warn][`init;"tickinterval is ",(string .z.m.tickinterval)," SECONDS - the batch flush and roll checks run that rarely"]];
  / singular and tabular roll daily - forced for the top-level mode only, never inside custom, as TorQ does
  if[.z.m.multilog in `singular`tabular;.z.m.multilogperiod:1D];
  / a period the tick cannot keep up with trips the past-period guard on every roll
  if[.z.m.multilogperiod<0D00:00:01*.z.m.tickinterval;
    .z.m.log[`warn][`init;"multilogperiod ",(string .z.m.multilogperiod)," is shorter than the ",(string .z.m.tickinterval),"s tick interval"]];
  .z.m.updfn:updfns .z.m.batchmode;
  .z.m.flushfn:flushfns .z.m.batchmode;
  .z.m.getlogsfn:getlogsfns .z.m.replayperiod;
  };

loadschema:{[config]
  / load the schema file at root; publishable tables are the unkeyed ones with time,sym first (as di.torq.proc.tickerplant)
  schemafile:$[`schemafile in key config;resolvedir[apphome[];config`schemafile];apphome[],"/database.q"];
  system "l ",schemafile;
  allt:tables[];
  t:allt where {(98h=type value x) and `time`sym~2#cols x} each allt;
  if[0=count t;raiseerror[`init;"schema file loaded no publishable tables (need unkeyed with time,sym first): ",schemafile]];
  {@[x;`sym;`g#]} each t;
  .z.m.pubtabs:t;
  .z.m.tabcols:t!cols each t;
  .z.m.schemas:t!{0#value x} each t;
  };

/ di.eodtime's merged init dict: the log dep plus any timezone config. built with ONE `!` over a general list -
/ amending keys onto enlist[`log]!enlist logdep (as di.torq.proc.tickerplant does) puts a TABLE on the value side,
/ since a one-element list of dicts is a table, and di.eodtime.init then throws 'type for any timezone setting.
/ rolltimeoffset is parsed like multilogperiod (a timespan, a "0D10:00:00" string, or seconds - TOML has no timespan
/ type); a value that cannot be parsed is dropped LOUDLY, at warn, not silently as a non-timespan would otherwise be
eoddeps:{[config;logdep]
  ks:`rolltimezone`datatimezone inter key config;
  tzvals:astz each config ks;
  off:$[`rolltimeoffset in key config;totimespan config`rolltimeoffset;0Nn];
  if[(`rolltimeoffset in key config) and null off;
    .z.m.log[`warn][`init;"rolltimeoffset ",(-3!config`rolltimeoffset)," is not a timespan, a timespan string or seconds - ignored"]];
  / a plain join, not ,: - amending a timespan onto a symbol vector in place throws 'type
  if[not null off;ks,:`rolltimeoffset;tzvals:tzvals,enlist off];
  vals:(1+count ks)#(::);
  vals[0]:logdep;
  if[count ks;vals[1+til count ks]:tzvals];
  (`log,ks)!vals
  };

publishroot:{[]
  / the IPC surface a feed and TorQ's .sub.subscribe call by name - use keeps module code in a private namespace
  set[`upd;upd];
  set[`.u.upd;upd];
  set[`.u.sub;sub];
  set[`tablelist;tablelist];
  set[`subdetails;subdetails];
  set[`tptype;`segmented];
  };

init:{[config;deps]
  / wire the injected deps, read config, load the schema, publish the root IPC surface, open the day's logs and
  / schedule the tick job. safe to call again, and to retry after a call that failed part-way
  checkdeps deps;
  if[.z.m.initdone;teardown[]];
  .z.m.log:deps`log;
  .z.m.logwired:1b;
  .z.m.timer:deps`timer;
  .z.m.handlers:deps`handlers;
  / a failed earlier init may have left handles open or a job/handler registered (both removals are no-ops if absent)
  releaselogs[];
  (.z.m.timer`deletejobs)[enlist jobid];
  (.z.m.handlers`remove)[`.z.exit;`;jobid];
  (.z.m.handlers`remove)[`.z.pc;`;`pubsub];
  readconfig config;
  loadschema config;
  .z.m.ps:use`di.pubsub;
  (.z.m.ps`setsubtables)[.z.m.pubtabs];
  (.z.m.ps`init)[];
  / di.pubsub's subscriber cleanup goes on .z.pc through the handlers dep (di.pubsub no longer binds .z.pc at load -
  / that replaced the di.torq.handlers dispatcher, and di.torq.servers' hook with it, moments after di.torq installed it)
  (.z.m.handlers`register)[`.z.pc;`;`pubsub;0;.z.m.ps`closesub];
  .z.m.eod:use`di.eodtime;
  (.z.m.eod`init)[eoddeps[config;.z.m.log]];
  .z.m.tp:use`di.tplogmgr;
  .z.m.custommode:(`symbol$())!`symbol$();
  if[.z.m.multilog=`custom;loadcustom config];
  .z.m.seqnum:0;
  publishroot[];
  startday[];
  (.z.m.timer`addjob)[jobid;tick;();.z.m.tickinterval;1h;jobopts];
  (.z.m.handlers`register)[`.z.exit;`;jobid;0;exithandler];
  msg:"initialised, multilog=",(string .z.m.multilog),", batchmode=",string .z.m.batchmode;
  .z.m.log[`info][`segmentedtp;msg,", tables=",", " sv string .z.m.pubtabs];
  / written last: a throw anywhere above leaves the module uninitialised, so a retry is a full init, not a re-init
  .z.m.initdone:1b;
  };

getapimeta:{[]
  / this module's api metadata, one row per CALLABLE API function, for di.torq to register with di.api. init and
  / getapimeta are plumbing di.torq calls by convention and are deliberately not listed. names are bare.
  :flip `name`public`descrip`params`return!flip(
    (`upd;           1b; "log and publish a feed update under the batch mode";       "[symbol|symbol list: t; list|table: x]";    "null");
    (`tablelist;     1b; "the publishable tables";                                   "[]";                                        "symbol list");
    (`subdetails;    1b; "subscribe the caller; return schemas and replay details";  "[symbol: tabs; symbols|null: instruments]"; "dict");
    (`readcustomcsv; 1b; "read a table,mode csv into a custom mode dict";            "[symbol|string: path]";                     "dict: table!mode");
    (`setcustommode; 1b; "replace the custom log assignment and reopen the logs";    "[dict: table!mode]";                        "null");
    (`getcounts;     1b; "per-table counted and pending counts, plus the seqnum";    "[]";                                        "dict");
    (`teardown;      1b; "close every log; remove the tick job and .z.exit handler"; "[]";                                        "null"));
  };
