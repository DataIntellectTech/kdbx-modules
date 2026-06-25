/ ===========================================================================
/ di.serverselect integration test
/ End-to-end narrative test driving every exported function through a
/ realistic gateway lifecycle: register -> activate/deactivate -> query ->
/ select -> bulk-register -> error handling. Complements the k4unit suite
/ in test.csv with assertions on real usage rather than per-call checks.
/ Run (QPATH must include this repo and the kx module dir):
/   QPATH=/path/to/kx/mod:/path/to/kdbx-modules q integration.q
/ Exits with a non-zero code equal to the number of failed assertions.
/ ===========================================================================

srvsel:use`di.serverselect

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

/ init must be called before use (log is a required injected dependency, no default).
/ use a no-op logger for the behavioural steps; STEP 13 exercises init itself.
srvsel.init[enlist[`log]!enlist `info`warn`error!({[m]};{[m]};{[m]})]

d1:2024.01.01; d2:2024.01.02; d3:2024.01.03

/ ===========================================================================
hdr"STEP 1  initial empty state (getserverstable)"
chk["fresh module: server table empty";0=count srvsel.getserverstable[];1b]
chk["schema columns correct";`serverid`handle`procname`servertype`hpup`active`lastp`hits`attributes;cols srvsel.getserverstable[]]

/ ===========================================================================
hdr"STEP 2  addserver (no attributes)"
srvsel.addserver[4i;`rdb]
srvsel.addserver[5i;`rdb]
chk["two rdb servers registered";2=count srvsel.getserverstable[];1b]
chk["serverids autoincrement from 1";1 2i;exec serverid from srvsel.getserverstable[]]
chk["addserver -> null procname";1b;all null exec procname from srvsel.getserverstable[]]
chk["addserver -> null hpup";1b;all null exec hpup from srvsel.getserverstable[]]
chk["addserver -> empty attributes dict";(()!());first exec attributes from srvsel.getserverstable[] where handle=4i]
chk["addserver -> active by default";1b;all exec active from srvsel.getserverstable[]]

/ ===========================================================================
hdr"STEP 3  addserverattr (servertype + attributes)"
srvsel.addserverattr[6i;`hdb;`date`sym!((d1;d2);`A`B)]
srvsel.addserverattr[7i;`hdb;`date`sym!((d2;d3);`B`C)]
chk["two hdb servers added";4=count srvsel.getserverstable[];1b]
chk["addserverattr stores attributes";`date`sym!((d1;d2);`A`B);first exec attributes from srvsel.getserverstable[] where handle=6i]
chk["addserverattr -> null procname";1b;null first exec procname from srvsel.getserverstable[] where handle=6i]

/ ===========================================================================
hdr"STEP 4  addserverfull (full details)"
srvsel.addserverfull[8i;`gw1;`gateway;`:host:5000;(enlist`region)!enlist`EU]
chk["fifth server registered";5=count srvsel.getserverstable[];1b]
chk["addserverfull -> procname populated";`gw1;first exec procname from srvsel.getserverstable[] where handle=8i]
chk["addserverfull -> hpup populated";`:host:5000;first exec hpup from srvsel.getserverstable[] where handle=8i]
chk["serverid sequence is 1..5";1 2 3 4 5i;exec serverid from srvsel.getserverstable[]]
chk["handles as registered";4 5 6 7 8i;exec handle from srvsel.getserverstable[]]
chk["servertypes as registered";`rdb`rdb`hdb`hdb`gateway;exec servertype from srvsel.getserverstable[]]

/ ===========================================================================
hdr"STEP 5  setserveractive (deactivate / reactivate)"
srvsel.setserveractive[5i;0b]
chk["handle 5 now inactive";0b;first exec active from srvsel.getserverstable[] where handle=5i]
chk["getservers excludes inactive rdb";1b;not 5i in exec handle from srvsel.getservers[`servertype;`rdb;()!()]]
srvsel.setserveractive[5i;1b]
chk["handle 5 reactivated";1b;first exec active from srvsel.getserverstable[] where handle=5i]
srvsel.setserveractive[9999i;0b]
chk["setserveractive on missing handle is a no-op";0=count select from srvsel.getserverstable[] where handle=9999i;1b]

/ ===========================================================================
hdr"STEP 6  getservers (lookup + attribute match scoring)"
chk["lookups=` returns all active";5;count srvsel.getservers[`;`;()!()]]
chk["servertype=hdb returns 2";2;count srvsel.getservers[`servertype;`hdb;()!()]]
chk["servertype list rdb,hdb returns 4";4;count srvsel.getservers[`servertype;`rdb`hdb;()!()]]
chk["procname=gw1 returns the gateway";enlist 8i;exec handle from srvsel.getservers[`procname;`gw1;()!()]]
chk["unknown servertype returns empty";0;count srvsel.getservers[`servertype;`nope;()!()]]
chk["attribmatch column present";1b;`attribmatch in cols srvsel.getservers[`;`;()!()]]
chk["complete date match flagged for some hdb";1b;any {x[`date]0} each (srvsel.getservers[`servertype;`hdb;(enlist`date)!enlist enlist d1])`attribmatch]

/ ===========================================================================
hdr"STEP 7  selector (strategies on a known table)"
seltab:([]serverid:101 102 103i;handle:201 202 203i;lastp:(2024.01.03D0;2024.01.01D0;2024.01.02D0))
chk["roundrobin picks oldest lastp";202i;(srvsel.selector[seltab;`roundrobin])`handle]
chk["last picks newest lastp";201i;(srvsel.selector[seltab;`last])`handle]
chk["any picks a row from the table";1b;((srvsel.selector[seltab;`any])`handle) in 201 202 203i]
single:([]serverid:enlist 9i;handle:enlist 99i;lastp:enlist 2024.06.01D0)
chk["single-row roundrobin returns that row";99i;(srvsel.selector[single;`roundrobin])`handle]
empt:([]serverid:`int$();handle:`int$();lastp:`timestamp$())
chk["empty table roundrobin -> null handle";0Ni;(srvsel.selector[empt;`roundrobin])`handle]
chk["empty table any -> null handle";0Ni;(srvsel.selector[empt;`any])`handle]

/ ===========================================================================
hdr"STEP 8  getserverbytype / gethandlebytype / gethpbytype"
chk["gethandlebytype rdb returns a live rdb handle";1b;(srvsel.gethandlebytype[`rdb;`roundrobin]) in 4 5i]
chk["gethpbytype gateway returns its hpup";`:host:5000;srvsel.gethpbytype[`gateway;`roundrobin]]
chk["getserverbytype returns requested column value";`gw1;srvsel.getserverbytype[`gateway;`procname;`roundrobin]]
chk["gethandlebytype unknown type -> ()";();srvsel.gethandlebytype[`nope;`roundrobin]]
chk["gethpbytype unknown type -> ()";();srvsel.gethpbytype[`nope;`roundrobin]]
/ round-robin rotation: with exactly 2 active rdbs, 4 LRU picks must cover both
rot:srvsel.gethandlebytype[`rdb] each 4#`roundrobin
chk["roundrobin rotates across both rdbs";4 5i;asc distinct rot]
/ selection bumps hits
hitsbefore:exec sum hits from srvsel.getserverstable[] where servertype=`gateway
srvsel.gethandlebytype[`gateway;`roundrobin]
chk["selection increments hits";1b;(hitsbefore+1)=exec sum hits from srvsel.getserverstable[] where servertype=`gateway]

/ ===========================================================================
hdr"STEP 9  getserverids - symbol (servertype) path"
chk["single servertype rdb -> rdb serverids";1 2i;asc raze srvsel.getserverids[`rdb]]
chk["servertype list rdb,hdb -> all four";1 2 3 4i;asc raze srvsel.getserverids[`rdb`hdb]]
srvsel.setserveractive[4i;0b]; srvsel.setserveractive[5i;0b]
chkerr["all requested servertype inactive -> error";{srvsel.getserverids[`rdb]}]
srvsel.setserveractive[4i;1b]; srvsel.setserveractive[5i;1b]

/ ===========================================================================
hdr"STEP 10  getserverids - attribute dict path"
chk["single attribute date=d1 matches hdb 6";1b;3i in raze srvsel.getserverids[enlist[`date]!enlist enlist d1]]
chk["cross (d1,d2)x(A,B) satisfied by hdb 6 alone";1b;3i in raze srvsel.getserverids[`date`sym!((d1;d2);`A`B)]]
chk["independent date(d1,d2,d3)";1b;0<count raze srvsel.getserverids[`date`sym`attributetype!((d1;d2;d3);`A`B`C;`independent)]]
chk["servertype key in dict: hdb date=d2 -> hdbs 6,7";3 4i;asc raze srvsel.getserverids[`servertype`date!(`hdb;enlist d2)]]
chk["empty requirement dict -> all active serverids";1 2 3 4 5i;asc raze srvsel.getserverids[()!()]]
chkerr["besteffort=0b impossible -> error";{srvsel.getserverids[`date`besteffort!(enlist 2099.01.01;0b)]}]
chkerr["no server has requested attribute value -> error";{srvsel.getserverids[enlist[`date]!enlist enlist 2099.01.01]}]

/ ===========================================================================
hdr"STEP 11  addserversfromtable (bulk registration)"
conntab:([]w:10 11i;proctype:`rdb`hdb;attributes:(()!();`date`sym!((d1;d2);`A`B)))
srvsel.addserversfromtable[`rdb`hdb;conntab]
chk["bulk-registered handles 10,11";2=count select from srvsel.getserverstable[] where handle in 10 11i;1b]
/ skip already-active handles (4 active, 12 new)
conntab2:([]w:4 12i;proctype:`rdb`rdb;attributes:(()!();()!()))
n0:count srvsel.getserverstable[]
srvsel.addserversfromtable[`rdb;conntab2]
chk["already-active handle 4 skipped, only 12 added";n0+1;count srvsel.getserverstable[]]
/ proctype filter: only rdb of a mixed table
conntab3:([]w:20 21i;proctype:`tickerplant`rdb;attributes:(()!();()!()))
srvsel.addserversfromtable[`rdb;conntab3]
chk["proctype filter registers only the rdb (handle 21)";1b;(0<count select from srvsel.getserverstable[] where handle=21i) and 0=count select from srvsel.getserverstable[] where handle=20i]
/ `ALL with optional procname + hpup columns
conntab4:([]w:30 31i;proctype:`rdb`hdb;procname:`p30`p31;hpup:`:h:30`:h:31;attributes:(()!();()!()))
srvsel.addserversfromtable[`ALL;conntab4]
chk["ALL + optional procname populated";`p30;first exec procname from srvsel.getserverstable[] where handle=30i]
chk["ALL + optional hpup populated";`:h:31;first exec hpup from srvsel.getserverstable[] where handle=31i]

/ ===========================================================================
hdr"STEP 12  error handling (every guarded path signals + logs)"
chkerr["addserverfull rejects non-int handle";{srvsel.addserverfull[`bad;`;`rdb;`;()!()]}]
chkerr["addserverfull rejects non-symbol servertype";{srvsel.addserverfull[71i;`;"rdb";`;()!()]}]
chkerr["addserver rejects bad handle";{srvsel.addserver[`bad;`rdb]}]
chkerr["addserverattr rejects bad servertype";{srvsel.addserverattr[73i;"hdb";()!()]}]
chkerr["setserveractive rejects non-int handle";{srvsel.setserveractive["bad";0b]}]
chkerr["setserveractive rejects non-boolean flag";{srvsel.setserveractive[1i;`yes]}]
chkerr["getservers rejects bad nameortype";{srvsel.getservers[`badname;`x;()!()]}]
chkerr["selector rejects unknown strategy";{srvsel.selector[seltab;`bogus]}]
chkerr["getserverids rejects null servertype";{srvsel.getserverids[`]}]
chkerr["getserverids rejects unregistered servertype";{srvsel.getserverids[`nope]}]
chkerr["getserverids rejects non-symbol non-dict arg";{srvsel.getserverids[42]}]
chkerr["addserversfromtable rejects missing columns";{srvsel.addserversfromtable[`rdb;([]x:enlist 1i)]}]

/ ===========================================================================
hdr"STEP 13  init (required log dependency - kx.log or bespoke)"
caplog:([]lvl:`symbol$();msg:())
caplogger:`info`warn`error!({[m]`caplog upsert(`info;m)};{[m]`caplog upsert(`warn;m)};{[m]`caplog upsert(`error;m)})
srvsel.init[enlist[`log]!enlist caplogger]
caplog:0#caplog
srvsel.addserver[40i;`rdb]
chk["injected logger captures an info message";1b;0<count select from caplog where lvl=`info]
chk["injected logger receives the message text";1b;any caplog[`msg] like "*registering server*"]
caplog:0#caplog
@[{srvsel.selector[([]handle:1 2i;lastp:2#.z.p);`bogus]};();{}]
chk["injected logger captures an error message";1b;0<count select from caplog where lvl=`error]
chkerr["init rejects non-dictionary deps";{srvsel.init[(::)]}]
chkerr["init rejects deps missing log key";{srvsel.init[()!()]}]
chkerr["init rejects log value that is not a dict";{srvsel.init[enlist[`log]!enlist(::)]}]
chkerr["init rejects log dict missing error key";{srvsel.init[enlist[`log]!enlist(`info`warn!({[m]};{[m]}))]}]
srvsel.init[enlist[`log]!enlist (use`kx.log)[`createLog][]]
srvsel.addserver[41i;`rdb]
chk["kx.log logger wired and usable";1b;41i in exec handle from srvsel.getservers[`servertype;`rdb;()!()]]

/ ===========================================================================
-1"";-1"===========================================================";
-1"  TOTAL: ",(string PASS+FAIL)," | PASS: ",(string PASS)," | FAIL: ",string FAIL;
-1"===========================================================";
exit FAIL
