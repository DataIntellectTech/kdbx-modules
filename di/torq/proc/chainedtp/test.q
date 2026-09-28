/ test helpers: recording mocks, a real upstream (segmented tickerplant surface) and a real downstream subscriber

logrows:([]lvl:`symbol$();ctx:`symbol$();msg:())
mocklog:`info`warn`error!({[c;m]`logrows upsert(`info;c;m)};{[c;m]`logrows upsert(`warn;c;m)};{[c;m]`logrows upsert(`error;c;m)})
timercalls:([]id:`symbol$();period:`long$();mode:`long$())
mocktimer:enlist[`addjob]!enlist {[id;func;params;period;mode;opts] `timercalls upsert (id;`long$period;`long$mode);}
handlercalls:([]event:`symbol$();name:`symbol$())
mockhandlers:`register`remove`list!({[ev;ph;nm;pri;fn]`handlercalls upsert(ev;nm)};{[ev;ph;nm]};{[ev]})
errlogged:{[s] any (exec msg from logrows where lvl=`error) like "*",s,"*"}

FIXDIR:"/tmp/dictptest"
D:2026.09.28
QBIN:first system "readlink -f /proc/",(string .z.i),"/exe"
isfree:{[p] not @[{hclose hopen x;1b};(`$":localhost:",string p;100);0b]}
waitlisten:{[p] d:.z.p+0D00:00:03; while[(.z.p<d) and isfree p; system "sleep 0.05"]; not isfree p}
UPPORT:0N; DNPORT:0N; uh:0N; dh:0N

/ upstream answers .sub.subscribe as a segmented tickerplant; downstream records upd and .u.end
setupfixture:{[]
  system "rm -rf ",FIXDIR; system "mkdir -p ",FIXDIR;
  (`$":",FIXDIR,"/up.q") 0: (
    "tptype:`segmented";
    "trade:([]time:`timestamp$();sym:`g#`symbol$();price:`float$())";
    "tablelist:{enlist`trade}";
    ".u.d:",string D;
    "subdetails:{[t;s] `schemalist`logfilelist`rowcounts`date`logdir!(enlist(`trade;0#trade);();(enlist`trade)!enlist 0;.u.d;`:",FIXDIR,")}");
  (`$":",FIXDIR,"/down.q") 0: ("got:()";"ended:()";"upd:{[t;x] got::got,enlist(t;x)}";".u.end:{ended::ended,x}");
  p:30000+(`int$.z.i mod 20000)+til 500; p:p where isfree each p;
  `UPPORT`DNPORT set' 2#p;
  {system QBIN," ",FIXDIR,"/",x," -p ",(string y)," -q </dev/null >/dev/null 2>&1 &"}'[("up.q";"down.q");(UPPORT;DNPORT)];
  if[not all waitlisten each UPPORT,DNPORT;'"test: peers failed to listen"];
  (`$":",FIXDIR,"/process.csv") 0: ("host,port,proctype,procname";"localhost,",(string UPPORT),",tickerplant,tickerplant1");
  }

svc:use`di.torq.servers
initservers:{[] svc.init[`log`timer`handlers`proctype`procname`processcsv`connections`discoveryregister`connectionsfromdiscovery!(mocklog;mocktimer;mockhandlers;`chainedtp;`chainedtp1;FIXDIR,"/process.csv";`tickerplant;0b;0b)]}

cfg:{[] `proctype`procname`autoreconnect`pubinterval!(`chainedtp;`chainedtp1;0b;0D)}
deps:{[] `log`timer`handlers!(mocklog;mocktimer;mockhandlers)}

rows:{[n] ([]time:n#.z.p;sym:n#`a`b;price:`float$til n)}

teardownfixture:{[] {@[{(neg x)"exit 0";(neg x)[]};x;()]} each (.ctp.tph;dh); system "sleep 0.3"; system "rm -rf ",FIXDIR;}
