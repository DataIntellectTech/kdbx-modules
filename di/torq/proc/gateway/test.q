/ shared mocks for di.torq.proc.gateway's tests. di.serverselect, di.asyncdispatch and
/ di.dataaccess are the REAL modules - only the four injected deps are mocked, so the tests
/ exercise the registry the gateway actually routes on.

/ --- log ---
calls:([]lvl:`symbol$();ctx:`symbol$();msg:())
resetcalls:{[] `calls set ([]lvl:`symbol$();ctx:`symbol$();msg:()); }
mocklogfn:{[lvl;ctx;msg] `calls insert (lvl;ctx;msg); }
mocklog:{[] `info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;])}

/ --- timer / handlers: record the registration and do nothing ---
jobs:`symbol$()
mockaddjob:{[i;f;p;pe;m;o] `jobs set jobs,i; }
mocktimer:{[] `addjob`deletejobs`enablejobs`disablejobs`getactivejobs!(mockaddjob;{[x]};{[x]};{[x]};{[]()})}
mockhandlers:{[] `register`remove`list!({[e;n;nm;p;f]};{[e;n]};{[e]()})}

/ --- servers ---
/ BACKENDS is what di.torq.servers would report as connected. A test edits it to bring a
/ backend "up" mid-session, which is the whole point: the gateway must notice.
BACKENDS:([]w:`int$();proctype:`symbol$();procname:`symbol$();hpup:`symbol$())
setbackends:{[t] `BACKENDS set t; }

/ only the hdb is up - the state the gateway starts in
hdbonly:{[] setbackends ([]w:enlist 7i;proctype:enlist`hdb;procname:enlist`hdb;hpup:enlist`:localhost:5302); }

/ the rdb has since connected - what di.torq.servers' retry leaves behind
hdbandrdb:{[] setbackends ([]w:7 10i;proctype:`hdb`rdb;procname:`hdb`rdb1;hpup:`:localhost:5302`:localhost:5304); }

mockgetservers:{[pt] select from BACKENDS where proctype=pt}
mockservers:{[] `startup`getservers`gethandlebytype`waitfortype!({[c]};mockgetservers;{[pt;sel] 0Ni};{[pt;t;p] 1b})}

mockdeps:{[] `log`timer`handlers`servers!(mocklog[];mocktimer[];mockhandlers[];mockservers[])}

cfg:{[] (enlist`backendtypes)!enlist `rdb`hdb}

/ what the gateway can actually ROUTE to: di.serverselect's table, which di.asyncdispatch
/ dispatches on. Neither module exposes it, so the tests read it directly rather than have
/ one of them grow an accessor for their benefit (same call as di.torq.proc.idb's tests).
routable:{[] exec distinct servertype from .m.di.0serverselect.servers where active}

/ di.torq.servers fires .servers.connectcustom (from retryrows) after every successful new
/ connection, and ships it as a no-op. 1b only once the gateway has replaced it with its own.
hookinstalled:{[] @[{100h=type value x};`.servers.connectcustom;{[e] 0b}]}

/ fire the hook exactly as di.torq.servers' retryrows does - with the connected rows
fireconnectcustom:{[] (value `.servers.connectcustom) BACKENDS; }

/ --- reload gate against a real gateway process: two backends that count the async messages they are sent ---
GWDIR:"/tmp/di_gw_k4unit_",string .z.i;
GWQ:first system "readlink -f /proc/",(string .z.i),"/exe";
GWREPLIES:();
/ start a q on an OS-assigned port (-p 0W); it writes its port to <name>.port; wait for it and return the port
/ (no port picking: a port with no listener can still be unbindable, which made picked ports flaky)
gwspawn:{[script;name]
  pf:GWDIR,"/",name,".port";
  system GWQ," ",GWDIR,"/",script," -p 0W -q </dev/null >",GWDIR,"/",name,".log 2>&1 &";
  {[pf;x] system "sleep 0.05"; x+1}[pf]/[{[pf;x] (x<100) and ()~key hsym`$pf}[pf];0];
  if[()~key hsym`$pf;'"test: ",name," did not start (see ",GWDIR,"/",name,".log)"];
  "J"$first read0 hsym`$pf};
/ the port and identity line each spawned q writes once it is listening
gwportline:{[name] "(hsym`$\"",GWDIR,"/",name,".port\") 0: enlist string system\"p\"; GWNAME:`",name,";"};
startgwfixture:{[]
  system "rm -rf ",GWDIR; system "mkdir -p ",GWDIR;
  {(hsym`$GWDIR,"/",x,".q") 0: ("trade:([]date:2#.z.d-1 0;time:`timestamp$.z.d-1 0;sym:`a`b;price:1 2f);";"SENT:0; .z.ps:{`SENT set SENT+1; value x};";gwportline x)} each ("rdb1";"hdb1");
  bp:gwspawn'[("rdb1.q";"hdb1.q");("rdb1";"hdb1")];
  (hsym`$GWDIR,"/process.csv") 0: ("host,port,proctype,procname";"localhost,",(string bp 0),",rdb,rdb1";"localhost,",(string bp 1),",hdb,hdb1");
  (hsym`$GWDIR,"/gw.q") 0: (
    "lg:`info`warn`error!3#enlist {[c;m]};";
    "tm:use`di.timer; tm.init enlist[`log]!enlist lg;";
    "td:`addjob`deletejobs`enablejobs`disablejobs`getactivejobs!(tm.addjob.custom;tm.deletejobs;tm.enablejobs;tm.disablejobs;tm.getactivejobs);";
    "hz:use`di.torq.handlers; hz.init enlist[`log]!enlist lg; hd:`register`remove`list!(hz.register;hz.remove;hz.list);";
    "svc:use`di.torq.servers; svc.init[`log`timer`handlers`proctype`procname`processcsv`connections`discoveryregister`connectionsfromdiscovery!(lg;td;hd;`gateway;`gateway1;\"",GWDIR,"/process.csv\";`rdb`hdb;0b;0b)];";
    "gw:use`di.torq.proc.gateway; gw.init[enlist[`backendtypes]!enlist`rdb`hdb;`log`timer`handlers`servers!(lg;td;hd;svc)];";
    gwportline "gw");
  gp:gwspawn["gw.q";"gw"];
  `GWH set hopen `$":localhost:",string gp;
  `GWBH set {hopen `$":localhost:",string x} each bp;
  / the listeners are the processes this fixture spawned
  if[not (`gw`rdb1`hdb1)~{x"GWNAME"} each GWH,GWBH;'"test: a port answered for a process this fixture did not spawn"];
  .z.ps:{`GWREPLIES set GWREPLIES,enlist x};
  };
/ send one async message to the gateway; returns the replies and what each backend (rdb;hdb) was sent
gwask:{[m]
  {x"SENT:0"} each GWBH;
  neg[GWH] m; neg[GWH][];
  system "sleep 1"; GWH"1";
  r:GWREPLIES; `GWREPLIES set ();
  `replies`sent!(r;{x"SENT"} each GWBH)};
/ a getdata spanning yesterday and today (an rdb and an hdb shard)
gwgetdata:{[] gwask (`.gw.getdata;`trade;`timestamp$.z.d-1;.z.p;`;())};
/ a getdata over today only (the rdb partition alone)
gwgetdatatoday:{[] gwask (`.gw.getdata;`trade;`timestamp$.z.d;.z.p;`;())};
/ asyncexec to the given server types
gwasync:{[t] gwask (`.gw.asyncexec;"count trade";t)};
stopgwfixture:{[]
  {@[{neg[x]"exit 0";neg[x][]};x;()]} each GWH,GWBH;
  system "sleep 0.3"; system "rm -rf ",GWDIR;
  };

