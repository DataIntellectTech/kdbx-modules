/ test helpers: segmented tickerplant peers per mode, chained peers, and this process as a .sub subscriber

FIXDIR:"/tmp/distptest"
QBIN:first system "readlink -f /proc/",(string .z.i),"/exe"
isfree:{[p] not @[{hclose hopen x;1b};(`$":localhost:",string p;100);0b]}
/ a peer writes its port once initialised
waitport:{[n] f:hsym`$FIXDIR,"/",string[n],".port"; d:.z.p+0D00:00:10; while[(.z.p<d) and ()~key f; system "sleep 0.05"]; $[()~key f;0Ni;"I"$first read0 f]}
start:{[n] system QBIN," ",FIXDIR,"/",string[n],".q -q </dev/null >",FIXDIR,"/",string[n],".log 2>&1 &"}
waitfor:{[f] d:.z.p+0D00:00:05; while[(.z.p<d) and not f[]; system "sleep 0.05"]; f[]}
peer:{[p] hopen `$":localhost:",string p}
alive:{[p] not isfree p}
PORTS:`a`b`c`s`p!5#0N

/ a: defaultbatch, tabperiod; b: immediate, singular; c: memorybatch, tabular; s: chained, create; p: chained, parent
CFGS:`a`b`c`s`p!(
  "`procname`schemafile`stplg!(`stp1;FIXDIR,\"/schema.q\";enlist[`kdbtplog]!enlist`$FIXDIR,\"/a\")";
  "`procname`schemafile`stplg!(`stp2;FIXDIR,\"/schema.q\";`kdbtplog`batchmode`multilog!(`$FIXDIR,\"/b\";`immediate;`singular))";
  "`procname`schemafile`stplg!(`stp3;FIXDIR,\"/schema.q\";`kdbtplog`batchmode`multilog!(`$FIXDIR,\"/c\";`memorybatch;`tabular))";
  "`procname`createlogs`autoreconnect`stplg`sctp!(`sctp1;0b;0b;enlist[`kdbtplog]!enlist`$FIXDIR,\"/s\";`chainedtp`loggingmode!(1b;`create))";
  "`procname`createlogs`autoreconnect`stplg`sctp!(`sctp2;0b;0b;enlist[`kdbtplog]!enlist`$FIXDIR,\"/p\";`chainedtp`loggingmode!(1b;`parent))")

setupfixture:{[]
  system "rm -rf ",FIXDIR; system "mkdir -p ",FIXDIR;
  (`$":",FIXDIR,"/schema.q") 0: (
    "trade:([]time:`timestamp$();sym:`g#`symbol$();price:`float$();size:`int$())";
    "quote:([]time:`timestamp$();sym:`g#`symbol$();bid:`float$())");
  {[n;c] (`$":",FIXDIR,"/",string[n],".q") 0: (
    "FIXDIR:\"",FIXDIR,"\"";
    "system \"p 0W\"";
    "errs:()";
    "nolog:`info`warn`error!({[c;m]};{[c;m]};{[c;m] errs::errs,enlist m})";
    "notimer:enlist[`addjob]!enlist {[a;b;c;d;e;f]}";
    "h:use`di.torq.handlers";
    "h.init enlist[`log]!enlist nolog";
    "hd:`register`remove`list#h";
    $[n in `s`p;"(use`di.torq.servers)[`init][`log`timer`handlers`proctype`procname`processcsv`connections`discoveryregister`connectionsfromdiscovery!(nolog;notimer;hd;`segmentedtp;`",string[n],";FIXDIR,\"/process.csv\";`segmentedtp;0b;0b)]";""];
    "system \"t 60000\"";
    "seg:use`di.torq.proc.segmentedtp";
    "seg.init[(enlist[`proctype]!enlist`segmentedtp),",c,";`log`timer`handlers!(nolog;notimer;hd)]";
    "(`$\":\",FIXDIR,\"/",string[n],".port\") 0: enlist string system \"p\"")}'[key CFGS;value CFGS];
  start each `a`b`c;
  PORTS[`a`b`c]:waitport each `a`b`c;
  if[any null PORTS`a`b`c;'"test: peers failed to start"];
  (`$":",FIXDIR,"/process.csv") 0: ("host,port,proctype,procname";"localhost,",(string PORTS`a),",segmentedtp,stp1");
  start each `s`p;
  PORTS[`s`p]:waitport each `s`p;
  if[any null PORTS`s`p;'"test: chained peers failed to start"];
  }

/ this process subscribes through .sub and records what it receives
got:(); eods:(); eops:()
upd:{[t;x] got::got,enlist(t;x)}
endofday:{[d;x] eods::eods,enlist(d;x)}
endofperiod:{[c;n;d] eops::eops,enlist(c;n;d)}
nolog:`info`warn`error!3#{[c;m]}
subs:use`di.subscriptions
subs.init[enlist[`autoreconnect]!enlist 0b;`log`timer`handlers!(nolog;enlist[`addjob]!enlist {[a;b;c;d;e;f]};`register`remove`list!({[a;b;c;d;e]};{[a;b;c]};{[a]}))]
.sub.AUTORECONNECT:0b
subto:{[h;n;tabs;syms] .sub.subscribe[tabs;syms;1b;0b;`procname`proctype`w!(n;`segmentedtp;h)]}

/ feed rows: list of columns, time added by the tickerplant
trd:{[s] (s;`float$til count s;`int$10*1+til count s)}
logcount:{[f] -11!(-2;f)}

teardownfixture:{[] {@[{h:peer x;(neg h)"exit 0";(neg h)[]};x;()]} each PORTS where alive each PORTS; system "sleep 0.3"; system "rm -rf ",FIXDIR;}
