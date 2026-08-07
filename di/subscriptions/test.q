/ fixture helpers for di.subscriptions' tests (loaded by test.csv).
/ two layers:
/   unit        - the tickerplant handle is a FUNCTION standing in for a handle (h(msg) applies to
/                 either), answering the real subdetails protocol and pointing at a REAL tp log
/                 built here, so every replay is genuine rather than simulated.
/   integration - a genuinely separate q process acting as a tickerplant: it writes its own tp log
/                 and serves a root-level subdetails, and we subscribe over real IPC. that is only
/                 possible because the wire contract is TorQ's real subdetails, not an invention.
/ NB each scenario uses its OWN table name. the double-subscribe guard deliberately refuses a table
/ that already has a live subscription, and a function handle always reports live, so reusing one
/ table across scenarios would trip the guard rather than test the behaviour under test.
/ this file is loaded at ROOT, so it is ordinary q - the module-context name-resolution rules that
/ apply inside subscriptions.q do not apply here.

BASE:"/tmp/disubscriptionstest";
D:2026.08.06;

/ --- capturing logger (assert on what the module logged, per di.permissions' pattern) ---
caprows:([]lvl:`symbol$();ctx:`symbol$();msg:());
resetcap:{[] `caprows set 0#caprows; };
caplog:`info`warn`error!(
  {[c;m] `caprows insert (`info;c;m)};
  {[c;m] `caprows insert (`warn;c;m)};
  {[c;m] `caprows insert (`error;c;m)});
/ di.handlers is MERGED (kdbx-modules main, #114), so the tests wire the REAL module rather than a
/ mock's guess at the register contract - the .z.pc observer path is then genuinely exercised.
/ NB use is called at TOP LEVEL and indexed, never dot-accessed from inside a lambda (h.init inside
/ a function throws 'h.init; only h[`init] works there)
realhandlers:use`di.handlers;
handlerdep:{[] :`register`remove!(realhandlers[`register];realhandlers[`remove]); };
/ NB one MULTI-key dict, not a chain of single-key ones: (enlist[`k]!enlist somedict) puts a TABLE
/ on the value side and joining two of them throws 'mismatch
deps:{[] :`log`handlers!(caplog;handlerdep[]); };
/ did any message at this level contain this substring? ss, not like - like throws 'nyi on a
/ multi wildcard pattern. NB the parameter is lv, NOT lvl: naming it lvl would shadow the column
/ and (lvl=lvl) would compare the column to itself, matching every row
logged:{[lv;s] :any {[s;m] 0<count m ss s}[s] each (),exec msg from caprows where lvl=lv; };

/ --- the schema a tickerplant hands back (g# on sym, as a real tp applies) ---
genschema:{[] :([]time:`timestamp$();sym:`g#`symbol$();price:`float$();size:`int$()); };

/ --- the root-level upd a subscriber defines; the replay drives this ---
updcalls:0;
rootupd:{[t;x]
  `updcalls set updcalls+1;
  @[`.;t;{[tab;d] tab upsert $[98h=type d;d;flip (cols tab)!d]}[;x]];
  };
resetupd:{[] `updcalls set 0; `upd set rootupd; };

/ --- tp log building ---
colsfor:{[i] :(enlist 2026.08.06D10:00+`timespan$60000000000*i;enlist `$"S",string i mod 4;
  enlist 1.0*i;enlist `int$10*i); };
msgfor:{[t;i] :(`upd;t;colsfor i); };
tabmsgfor:{[t;i] :(`upd;t;flip (cols genschema[])!colsfor i); };

logdir:{[nm] dir:BASE,"/",nm; system "mkdir -p ",dir; :dir; };
logpath:{[nm] :hsym`$(logdir nm),"/tp",string D; };

writelog:{[nm;msgs]
  / write the given messages to a fresh log and return its path
  lf:logpath nm;
  h:hopen lf set ();
  {[h;m] h enlist m}[h] each msgs;
  hclose h;
  :lf;
  };

buildlog:{[nm;t;n] :writelog[nm;msgfor[t] each til n]; };
buildtablepayloadlog:{[nm;t;n] :writelog[nm;tabmsgfor[t] each til n]; };
buildmixedlog:{[nm;ta;tb;n] :writelog[nm;raze {[ta;tb;i] (msgfor[ta;i];msgfor[tb;i])}[ta;tb] each til n]; };

writelogas:{[nm;fname;msgs]
  / write a log under an EXPLICIT file name - used for the log-name-carries-no-date case
  lf:hsym`$(logdir nm),"/",fname;
  h:hopen lf set ();
  {[h;m] h enlist m}[h] each msgs;
  hclose h;
  :lf;
  };

/ payload-shape variants. a tickerplant may log a list of columns (the classic shape), a table, a
/ dict, or a single atom row - all four are valid and the sym filter must handle each
dictmsgfor:{[t;i] :(`upd;t;(cols genschema[])!colsfor i); };
atommsgfor:{[t;i] :(`upd;t;first each colsfor i); };
builddictlog:{[nm;t;n] :writelog[nm;dictmsgfor[t] each til n]; };
buildatomlog:{[nm;t;n] :writelog[nm;atommsgfor[t] each til n]; };

/ a table with no sym column at all - a sym-filtered subscription must pass it through untouched
nosymschema:{[] :([]time:`timestamp$();val:`float$()); };
nosymmsgfor:{[t;i] :(`upd;t;(enlist 2026.08.06D10:00+`timespan$60000000000*i;enlist 1.0*i)); };
buildnosymlog:{[nm;t;n] :writelog[nm;nosymmsgfor[t] each til n]; };

truncatelog:{[lf;nbytes]
  / lop bytes off the tail so the last message is unreadable. NB (f set read1 g) would SERIALISE the
  / byte vector rather than copy the log - raw bytes must go through 1:
  raw:read1 lf;
  lf 1: (neg nbytes) _ raw;
  };

goodmsgs:{[lf] i:-11!(-2;lf); :$[1<count i;first i;i]; };

/ --- mock tickerplant handles ---
subdetailsresponse:{[pairs;n;lf;msg]
  / the real subdetails shape a tickerplant returns. pairs is a list of (tablename;schema)
  :`schemalist`logfilelist`rowcounts`date!(
    pairs;
    $[0=n;();enlist (n;lf)];
    (pairs[;0])!(count pairs)#n;
    D);
  };

mktph:{[pairs;n;lf]
  / a function standing in for a tickerplant handle - h(msg) applies to a function or an int handle
  :subdetailsresponse[pairs;n;lf];
  };

rawresponse:{[pairs;entries;counts;msg]
  / a responder taking the logfilelist VERBATIM, so a test can supply several log files (a segmented
  / tickerplant writes one per table), a null log file, or a zero message count
  :`schemalist`logfilelist`rowcounts`date!(pairs;entries;counts;D);
  };

mkrawtph:{[pairs;entries;counts] :rawresponse[pairs;entries;counts]; };

CALLEDWITH:`;
namedcapture:{[inner;msg]
  / record which remote function name subscribe actually asked for, then delegate
  `CALLEDWITH set first msg;
  :inner msg;
  };
mknamedtph:{[inner] :namedcapture[inner]; };

tphfor:{[t;n;lf] :mktph[enlist (t;genschema[]);n;lf]; };

mktphlogdir:{[t;n;lf] f:tphfor[t;n;lf]; :{[f;msg] :(f msg),enlist[`logdir]!enlist `$BASE; }[f]; };

mocktphbadshape:{[msg] :42; };
mocktphmissingkeys:{[msg] :enlist[`schemalist]!enlist enlist (`nosuch;genschema[]); };
mocktphthrows:{[msg] '"tickerplant exploded"; };
mocktphnotables:{[msg] :`schemalist`logfilelist`rowcounts`date!((();());();()!();D); };

/ --- integration: a genuinely separate q process acting as a tickerplant ---
PEERPORT:0N;
PEERPID:0N;
PEERDIR:"/tmp/disubscriptionspeer";
PEERMSGS:6;

isfree:{[p] :not @[{hclose hopen x;1b};(`$":localhost:",string p;100);{[e] :0b}]; };
pickport:{[start] :first (start+til 500) where isfree each start+til 500; };
waitlisten:{[port;timeoutms]
  deadline:.z.p+`timespan$1000000*timeoutms;
  while[(.z.p<deadline) and isfree port; system "sleep 0.05"];
  :not isfree port;
  };

peerlines:{[]
  / the peer's source, one COMPLETE string per line. NB no line is built with a trailing-comma
  / continuation: a q expression ends at the newline, so a split list literal silently becomes
  / several expressions rather than one element
  l:enlist "D:2026.08.06;";
  l,:enlist "LF:hsym`$\"",PEERDIR,"/tp\",string D;";
  l,:enlist "peerschema:([]time:`timestamp$();sym:`g#`symbol$();price:`float$();size:`int$());";
  l,:enlist "N:",string PEERMSGS;
  l,:enlist "cols4:{[i] (enlist 2026.08.06D10:00+`timespan$60000000000*i;enlist `$\"S\",string i mod 4;";
  l,:enlist "  enlist 1.0*i;enlist `int$10*i)};";
  l,:enlist "mk:{[i] (`upd;`peertrade;cols4 i)};";
  l,:enlist "lh:hopen LF set ();";
  l,:enlist "{[h;i] h enlist mk i}[lh] each til N;";
  l,:enlist "subs:();";
  l,:enlist "sd:{[tabs;instruments] subs::distinct subs,.z.w;";
  l,:enlist "  `schemalist`logfilelist`rowcounts`date!(enlist(`peertrade;peerschema);";
  l,:enlist "  enlist(N;LF);(enlist `peertrade)!enlist N;D)};";
  l,:enlist "subdetails:sd;";
  / pub logs a message AND publishes it live to every subscriber, exactly as a tickerplant does -
  / this is what makes the exactly-once boundary (replay then live) testable end to end
  l,:enlist "pub:{[i;s] m:(`upd;`peertrade;(enlist 2026.08.06D11:00+`timespan$1000000000*i;enlist s;";
  l,:enlist "  enlist 1.0*i;enlist `int$i)); lh enlist m; N+:1; {[m;w] (neg w) m}[m] each subs; N};";
  l,:enlist "logged:{[] N};";
  :l;
  };

writepeerscript:{[]
  / the peer writes its OWN tp log then serves a root-level subdetails - exactly the protocol
  / chainedtp.q and segmentedtickerplant.q expose to subscribers
  (`$":",PEERDIR,"/tp.q") 0: peerlines[];
  };

spawnpeer:{[]
  system "rm -rf ",PEERDIR;
  system "mkdir -p ",PEERDIR;
  `PEERPORT set pickport 21000+`int$.z.i mod 10000;
  writepeerscript[];
  system (getenv[`QHOME]),"/bin/q ",PEERDIR,"/tp.q -p ",string[PEERPORT]," -q </dev/null >/dev/null 2>&1 &";
  if[not waitlisten[PEERPORT;5000];'"test: tickerplant peer failed to listen on ",string PEERPORT];
  h:hopen (`$":localhost:",string PEERPORT;2000);
  `PEERPID set h ".z.i";
  hclose h;
  };

peerhandle:{[] :hopen (`$":localhost:",string PEERPORT;2000); };
noticedrop:{[h]
  / a dead peer is only detected when we next touch the handle; that is what fires .z.pc
  @[{x "1+1"};h;{[e] :(::)}];
  system "sleep 0.3";
  };

flushpeer:{[h]
  / force this process to read the async messages the peer pushed at us. a synchronous round trip
  / makes q service the incoming queue, so the live upd calls land before we assert on them
  h "1+1";
  system "sleep 0.2";
  h "1+1";
  };
killpeer:{[] if[not null PEERPID;@[system;"kill ",string PEERPID;{[e] :(::)}]]; `PEERPID set 0N; system "sleep 0.3"; };

setupfixture:{[] system "rm -rf ",BASE; system "mkdir -p ",BASE; };
teardownfixture:{[] killpeer[]; system "rm -rf ",BASE; system "rm -rf ",PEERDIR; };
