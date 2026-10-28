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

/ the gateway's post-init hook, which di.torq calls as .gateway.run[] once everything has loaded
runhook:{[] (value `.gateway.run)[]}
warned:{[] 0<count select from calls where lvl=`warn,msg like "*NOT checked at this gateway*"}

/ config with permissioned set, for the warning test
cfgwith2:{[] `backendtypes`permissioned!(`rdb`hdb;1b)}
