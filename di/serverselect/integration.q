/ ===========================================================================
/ di.serverselect integration test (real processes)
/ Spawns child q listeners, opens REAL IPC handles to them, and drives every
/ exported function through a realistic gateway lifecycle - register ->
/ query -> select -> route a live query to the chosen handle -> bulk-register
/ -> disconnect -> error handling -> init. Unlike a simulated test, the
/ selection functions hand back handles that are actually queried, so the
/ assertions prove queries reach the expected backend process.
/ .
/ Self-contained: no helper files. The child backends are bare `q` listeners
/ whose identity (`whoami`) and `ping` api are injected over IPC at setup; the
/ test launches and tears them down itself.
/ .
/ Requirements:
/   - run THIS script with KDB-X q (needs `use`)
/   - a q on PATH (override with $QBIN) to launch the child listeners
/   - some free TCP ports: the test scans for free ports from a pid-derived
/     base (so concurrent runs don't collide); set $SSPORT to pin the base
/ Run (QPATH must include this repo and the kx module dir):
/   QPATH=/path/to/kx/mod:/path/to/kdbx-modules <kdbx>/q integration.q
/ Exits with a non-zero code equal to the number of failed assertions.
/ ===========================================================================

srvsel:use`di.serverselect;

/ ---- tiny assertion harness ----
/ note: avoid `desc`/`exp`/`log` as names - they are reserved words in KDB-X
PASS:0; FAIL:0;
lbl:{[ok] $[ok;"  ok   | ";"  FAIL | "]};
chk:{[nm;got;expd]
  ok:got~expd;
  $[ok;PASS+:1;FAIL+:1];
  m:lbl[ok],nm;
  if[not ok; m:m," || got=",(.Q.s1 got),"  exp=",.Q.s1 expd];
  -1 m;
  };
errtok:`$"__ERRORED__";
chkerr:{[nm;f]
  r:@[f;();{[e](errtok;e)}];
  ok:(0<count r) and errtok~first r;
  $[ok;PASS+:1;FAIL+:1];
  m:lbl[ok],nm;
  m:m,$[ok;" || signalled: ",(r 1);" || NO ERROR raised, got=",.Q.s1 r];
  -1 m;
  };
hdr:{[t] -1""; -1"==== ",t," ===="; };

d1:2024.01.01; d2:2024.01.02; d3:2024.01.03;

/ ---- child-process management ----
qbin:$[0<count s:getenv`QBIN; s; "q"];
/ fleet: 0,1 rdb | 2,3 hdb (attr) | 4 gateway | 5,6 bulk-registered rdb/hdb
names:`rdb1`rdb2`hdb1`hdb2`gw1`rdb3`hdb3;
pids:`int$();

/ no hardcoded ports: derive a starting point from this pid (so concurrent runs
/ on a shared host don't collide) - or take an explicit base from $SSPORT - then
/ scan upward for ports that are actually free. nothing assumes a fixed port.
inuse:{[p] @[{hclose hopen x; 1b}; (`$":localhost:",string p;200); 0b]};
baseport:$[0<count s:getenv`SSPORT; "I"$s; 20000+`int$.z.i mod 20000];
findfree:{[start;n]
  / take the first n free ports from a generous candidate window above start
  cand:start+til 10*n;
  free:cand where not inuse each cand;
  if[n>count free;
    '"could not find ",string[n]," free ports scanning up from ",string start];
  :n#free;
  };
ports:findfree[baseport;count names];

launch:{[port]
  / start a bare q listener detached (no script needed - identity is injected over IPC)
  system qbin," -p ",string[port]," -q </dev/null >/dev/null 2>&1 &";
  };

connect:{[port]
  / open a handle, retrying for up to ~10s while the child binds and accepts
  hp:`$":localhost:",string port;
  step:{[hp;h] if[not null h; :h]; system"sleep 0.2"; @[hopen;(hp;500);{0Ni}]}[hp];
  :50 step/ 0Ni;
  };

teardown:{[]
  / always-run cleanup. first kill by captured pid (exact); then a port-based
  / fallback so children are reaped even when we never connected (no pid).
  / the [-]p bracket keeps the pattern from matching this very kill command.
  live:pids where not null pids;
  if[count live; @[system;"kill ",(" " sv string live)," 2>/dev/null; true";{}]];
  {@[system;"pkill -f \"bin/q [-]p ",string[x],"\" 2>/dev/null; true";{}]} each ports;
  @[hclose;;{}] each handles where not null handles;
  };

/ launch the fleet, connect, capture each child's own pid (.z.i) for exact-pid teardown
-1 "selected free ports: ",.Q.s1 ports;
launch each ports;
handles:connect each ports;
pids:{$[null x; 0Ni; @[x;".z.i";{0Ni}]]} each handles;
/ guarantee the fleet is reaped on ANY exit (normal, error-abort, or exit code)
.z.exit:{teardown[]};
if[any null handles;
  -2 "failed to connect to child processes on ports: ",(" " sv string ports where null handles);
  exit 3];
/ inject each backend's identity + ping api over IPC
{[h;nm] h "whoami:`",string nm; h "ping:{whoami}";}'[handles;names];
-1 "spawned ",(string count handles)," backend processes; real handles: ",.Q.s1 handles;

/ route: select a server of type t via strategy sel, then SEND ping[] over the chosen handle
route:{[t;sel] h:srvsel.gethandlebytype[t;sel]; $[()~h; `NONE; h "ping[]"]};
/ map serverids -> their handles (to route attribute-path selections)
sidhandles:{[sids] exec handle from srvsel.getserverstable[] where serverid in sids};
/ the gateway's host/port for the hpup column - its real (dynamically chosen) address
gwhp:`$":localhost:",string ports 4;

/ test steps run at top level (a single enclosing function would exceed q's
/ per-function constant limit). chk/chkerr trap their own assertion failures;
/ .z.exit guarantees teardown regardless of how the script ends.

/ init must be called before use (log is a required injected dependency, no default)
srvsel.init[enlist[`log]!enlist `info`warn`error!({[c;m]};{[c;m]};{[c;m]})];

/ =========================================================================
hdr"STEP 1  initial empty state";
chk["fresh module: server table empty";0=count srvsel.getserverstable[];1b];
chk["schema columns correct";`serverid`handle`procname`servertype`hpup`active`lastp`hits`attributes;cols srvsel.getserverstable[]];

/ =========================================================================
hdr"STEP 2  registration of live handles (addserver / addserverattr / addserverfull)";
srvsel.addserver[handles 0;`rdb];
srvsel.addserver[handles 1;`rdb];
srvsel.addserverattr[handles 2;`hdb;`date`sym!((d1;d2);`A`B)];
srvsel.addserverattr[handles 3;`hdb;`date`sym!((d2;d3);`B`C)];
srvsel.addserverfull[handles 4;`gw1;`gateway;gwhp;(enlist`region)!enlist`EU];
chk["five servers registered";5=count srvsel.getserverstable[];1b];
chk["serverids autoincrement 1..5";1 2 3 4 5i;exec serverid from srvsel.getserverstable[]];
chk["handles stored are the real open handles";handles til 5;exec handle from srvsel.getserverstable[]];
chk["servertypes as registered";`rdb`rdb`hdb`hdb`gateway;exec servertype from srvsel.getserverstable[]];
chk["addserverfull populated procname";`gw1;first exec procname from srvsel.getserverstable[] where servertype=`gateway];
chk["addserverfull populated hpup";gwhp;first exec hpup from srvsel.getserverstable[] where servertype=`gateway];
chk["addserver -> empty attributes";(()!());first exec attributes from srvsel.getserverstable[] where handle=handles 0];
chk["all active by default";1b;all exec active from srvsel.getserverstable[]];

/ =========================================================================
hdr"STEP 3  getservers (lookup + attribute match scoring)";
chk["lookups=` returns all active";5;count srvsel.getservers[`;`;()!()]];
chk["servertype=hdb returns 2";2;count srvsel.getservers[`servertype;`hdb;()!()]];
chk["servertype list rdb,hdb returns 4";4;count srvsel.getservers[`servertype;`rdb`hdb;()!()]];
chk["procname=gw1 returns the gateway handle";enlist handles 4;exec handle from srvsel.getservers[`procname;`gw1;()!()]];
chk["unknown servertype returns empty";0;count srvsel.getservers[`servertype;`nope;()!()]];
chk["attribmatch column present";1b;`attribmatch in cols srvsel.getservers[`;`;()!()]];
chk["complete date match flagged for some hdb on d1";1b;
  any {x[`date]0} each (srvsel.getservers[`servertype;`hdb;(enlist`date)!enlist enlist d1])`attribmatch];

/ =========================================================================
hdr"STEP 4  selector (strategies on a known table)";
seltab:([]serverid:101 102 103i;handle:201 202 203i;lastp:(2024.01.03D0;2024.01.01D0;2024.01.02D0));
chk["roundrobin picks oldest lastp";202i;(srvsel.selector[seltab;`roundrobin])`handle];
chk["last picks newest lastp";201i;(srvsel.selector[seltab;`last])`handle];
chk["any picks a row from the table";1b;((srvsel.selector[seltab;`any])`handle) in 201 202 203i];
empt:([]serverid:`int$();handle:`int$();lastp:`timestamp$());
chk["empty table -> null handle";0Ni;(srvsel.selector[empt;`roundrobin])`handle];

/ =========================================================================
hdr"STEP 5  live routing (gethandlebytype / gethpbytype / getserverbytype)";
/ round-robin across the two live rdbs: both start with null lastp, so LRU
/ visits rdb1, rdb2, rdb1, rdb2 - and each query is answered by that process
resp:{[i] route[`rdb;`roundrobin]} each til 4;
chk["round-robin routes to live rdbs in LRU order";`rdb1`rdb2`rdb1`rdb2;resp];
chk["only the two live rdbs ever answer";`rdb1`rdb2;asc distinct resp];
chk["gethpbytype gateway returns its hpup";gwhp;srvsel.gethpbytype[`gateway;`roundrobin]];
chk["getserverbytype returns requested column";`gw1;srvsel.getserverbytype[`gateway;`procname;`roundrobin]];
chk["gethandlebytype unknown type -> ()";();srvsel.gethandlebytype[`nope;`roundrobin]];
chk["a single hdb query is answered by an hdb";1b;(route[`hdb;`roundrobin]) in `hdb1`hdb2];
hitsbefore:exec sum hits from srvsel.getserverstable[] where servertype=`gateway;
srvsel.gethandlebytype[`gateway;`roundrobin];
chk["selection increments hits";1b;(hitsbefore+1)=exec sum hits from srvsel.getserverstable[] where servertype=`gateway];

/ =========================================================================
hdr"STEP 6  getserverids - servertype (symbol) path";
chk["rdb -> the two rdb serverids";1 2i;asc raze srvsel.getserverids[`rdb]];
chk["rdb,hdb -> all four serverids";1 2 3 4i;asc raze srvsel.getserverids[`rdb`hdb]];
srvsel.setserveractive[handles 0;0b]; srvsel.setserveractive[handles 1;0b];
chkerr["all requested servertype inactive -> error";{srvsel.getserverids[`rdb]}];
srvsel.setserveractive[handles 0;1b]; srvsel.setserveractive[handles 1;1b];

/ =========================================================================
hdr"STEP 7  getserverids - attribute path + routing to the matched backend";
/ hdb1 covers (d1,d2)/(A,B); hdb2 covers (d2,d3)/(B,C)
chk["date=d1 -> hdb1 only";enlist`hdb1;
  distinct {x"ping[]"} each sidhandles raze srvsel.getserverids[enlist[`date]!enlist enlist d1]];
chk["cross (d1,d2)x(A,B) -> hdb1 alone covers it";enlist`hdb1;
  distinct {x"ping[]"} each sidhandles raze srvsel.getserverids[`date`sym!((d1;d2);`A`B)]];
chk["independent over d1,d2,d3 + A,B,C -> both hdbs contribute";`hdb1`hdb2;
  asc distinct {x"ping[]"} each sidhandles raze srvsel.getserverids[`date`sym`attributetype!((d1;d2;d3);`A`B`C;`independent)]];
chk["servertype key scopes attribute filter to hdbs";3 4i;asc raze srvsel.getserverids[`servertype`date!(`hdb;enlist d2)]];
chk["empty requirement dict -> all active serverids";1 2 3 4 5i;asc raze srvsel.getserverids[()!()]];
chkerr["besteffort=0b impossible -> error";{srvsel.getserverids[`date`besteffort!(enlist 2099.01.01;0b)]}];
chkerr["no server has requested attribute value -> error";{srvsel.getserverids[enlist[`date]!enlist enlist 2099.01.01]}];

/ =========================================================================
hdr"STEP 8  addserversfromtable (bulk registration of live handles)";
conntab:([]w:handles 5 6;proctype:`rdb`hdb;attributes:(()!();`date`sym!((d1;d3);`A`C)));
srvsel.addserversfromtable[`rdb`hdb;conntab];
chk["bulk-registered handles 5,6 now present";2=count select from srvsel.getserverstable[] where handle in handles 5 6;1b];
chk["bulk-registered rdb3 is reachable via its handle";`rdb3;(handles 5)"ping[]"];
chk["bulk-registered rdb3 now appears in rdb serverids";1b;6i in raze srvsel.getserverids[`rdb]];
/ skip-already-active: re-offering a live handle must not duplicate it
n0:count srvsel.getserverstable[];
srvsel.addserversfromtable[`rdb;([]w:enlist handles 0;proctype:enlist`rdb;attributes:enlist()!())];
chk["already-active handle skipped (no new row)";n0;count srvsel.getserverstable[]];
/ (proctype filter, `ALL, and optional procname/hpup columns are covered in test.csv)

/ =========================================================================
hdr"STEP 9  disconnect: kill a backend, deactivate it, prove routing adapts";
/ a real gateway's .z.pc handler would call setserveractive[h;0b] on the dropped handle
@[system;"kill ",string[pids 0]," 2>/dev/null; true";{}]; system"sleep 0.3";
srvsel.setserveractive[handles 0;0b];
/ active rdbs are now rdb2 (live) and rdb3 (live); the dead rdb1 must never be picked
postresp:{[i] route[`rdb;`roundrobin]} each til 6;
chk["killed/deactivated rdb1 is never selected";1b;not `rdb1 in postresp];
chk["no routed query hits a dead handle (all answered)";1b;not `NONE in postresp];
chk["the two remaining live rdbs both serve";`rdb2`rdb3;asc distinct postresp];

/ =========================================================================
hdr"STEP 10  error handling (every guarded path signals + logs)";
chkerr["addserverfull rejects non-int handle";{srvsel.addserverfull[`bad;`;`rdb;`;()!()]}];
chkerr["addserverfull rejects non-symbol servertype";{srvsel.addserverfull[71i;`;"rdb";`;()!()]}];
chkerr["addserver rejects bad handle";{srvsel.addserver[`bad;`rdb]}];
chkerr["addserverattr rejects bad servertype";{srvsel.addserverattr[73i;"hdb";()!()]}];
chkerr["setserveractive rejects non-int handle";{srvsel.setserveractive["bad";0b]}];
chkerr["setserveractive rejects non-boolean flag";{srvsel.setserveractive[1i;`yes]}];
chkerr["getservers rejects bad nameortype";{srvsel.getservers[`badname;`x;()!()]}];
chkerr["selector rejects unknown strategy";{srvsel.selector[seltab;`bogus]}];
chkerr["getserverids rejects null servertype";{srvsel.getserverids[`]}];
chkerr["getserverids rejects unregistered servertype";{srvsel.getserverids[`nope]}];
chkerr["getserverids rejects non-symbol non-dict arg";{srvsel.getserverids[42]}];
chkerr["getserverids rejects nested/malformed attribute value";{srvsel.getserverids[(enlist`date)!enlist enlist d1,d2]}];
chkerr["addserversfromtable rejects missing columns";{srvsel.addserversfromtable[`rdb;([]x:enlist 1i)]}];

/ =========================================================================
hdr"STEP 11  init (required log dependency - bespoke + kx.log)";
caplog:([]lvl:`symbol$();msg:());
caplogger:`info`warn`error!({[c;m]`caplog upsert(`info;m)};{[c;m]`caplog upsert(`warn;m)};{[c;m]`caplog upsert(`error;m)});
srvsel.init[enlist[`log]!enlist caplogger];
caplog:0#caplog;
srvsel.addserver[40i;`rdb];
chk["injected logger captures an info message";1b;0<count select from caplog where lvl=`info];
chk["injected logger receives the message text";1b;any caplog[`msg] like "*registering server*"];
caplog:0#caplog;
@[{srvsel.selector[([]handle:1 2i;lastp:2#.z.p);`bogus]};();{}];
chk["injected logger captures an error message";1b;0<count select from caplog where lvl=`error];
chkerr["init rejects non-dictionary deps";{srvsel.init[(::)]}];
chkerr["init rejects deps missing log key";{srvsel.init[()!()]}];
chkerr["init rejects log value that is not a dict";{srvsel.init[enlist[`log]!enlist(::)]}];
chkerr["init rejects log dict missing error key";{srvsel.init[enlist[`log]!enlist(`info`warn!({[c;m]};{[c;m]}))]}];
srvsel.init[enlist[`log]!enlist (use`kx.log)[`createLog][]];
srvsel.addserver[41i;`rdb];
chk["kx.log logger wired and usable";1b;41i in exec handle from srvsel.getservers[`servertype;`rdb;()!()]];

-1"";-1"===========================================================";
-1"  TOTAL: ",(string PASS+FAIL)," | PASS: ",(string PASS)," | FAIL: ",string FAIL;
-1"===========================================================";
exit FAIL
