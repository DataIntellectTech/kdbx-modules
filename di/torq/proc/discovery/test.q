/ di.torq.proc.discovery test helpers (loaded by test.csv): mock log/handlers, stubbed .servers.*
/ root names that record their calls, and two real q peers so the .z.w/.z.W paths run over
/ genuine handles (a peer calls back into this process over the handle it was asked on).

logrows:([]lvl:`symbol$();ctx:`symbol$();msg:());
mocklog:`info`warn`error!({[c;m]`logrows upsert(`info;c;m)};{[c;m]`logrows upsert(`warn;c;m)};{[c;m]`logrows upsert(`error;c;m)});

handlercalls:([]event:`symbol$();name:`symbol$();func:());
mockhandlers:enlist[`register]!enlist {[ev;ph;nm;pri;fn]`handlercalls upsert(ev;nm;fn)};
pcfunc:{[] last exec func from handlercalls where event=`.z.pc,name=`discovery};

calls:([]fn:`symbol$();arg:());
rec:{[f;a]`calls upsert(f;a);};
argsof:{[f] exec arg from calls where fn=f};

/ the .servers.* names discovery.q calls, recording instead of connecting
stubservers:{[]
  .servers.SERVERS::([]procname:`symbol$();proctype:`symbol$();hpup:`symbol$();w:`int$();attributes:());
  .servers.nontorqprocesstab::([]hpup:`symbol$());
  .servers.startup::{rec[`startup;x]};
  .servers.cleanup::{rec[`cleanup;::]};
  .servers.addw::{rec[`addw;x];x};
  .servers.removerows::{rec[`removerows;x]; delete from `.servers.SERVERS where i in x};
  .dotz.liveh::{x in key .z.W};
  };

row:{[pn;pt;hp;wh] ([]procname:enlist pn;proctype:enlist pt;hpup:enlist hp;w:enlist wh;attributes:enlist ()!())};

/ peer A (alpha) and peer B (beta) live; B's hpup listed as a non-torq process
initrows:{[]
  .servers.SERVERS::row[`alpha1;`alpha;`:a:1;hA],row[`beta1;`beta;`:b:2;hB];
  .servers.nontorqprocesstab::([]hpup:enlist`:b:2);
  };

/ alpha/beta plus discovery's own row, no non-torq rows
servicerows:{[]
  .servers.SERVERS::row[`alpha1;`alpha;`:a:1;hA],row[`beta1;`beta;`:b:2;hB],row[`discovery1;`discovery;`:d:3;0Ni];
  .servers.nontorqprocesstab::([]hpup:`symbol$());
  };

/ a stale row sharing peer B's host:port on another handle - register must remove it
registerrows:{[] servicerows[]; .servers.SERVERS::.servers.SERVERS,row[`beta1;`beta;`:b:2;0Ni];};

/ --- real peer fixture ---
FIXDIR:"/tmp/didiscoverytest";
QBIN:first system "readlink -f /proc/",(string .z.i),"/exe";
isfree:{[p] not @[{hclose hopen x;1b};(`$":localhost:",string p;100);0b]};
pickport:{[start] first (start+til 500) where isfree each start+til 500};
waitlisten:{[p] d:.z.p+0D00:00:03; while[(.z.p<d) and isfree p; system "sleep 0.05"]; not isfree p};
PORTA:0N; PORTB:0N; hA:0N; hB:0N;

/ each peer records what discovery pushes to it in `got
setupfixture:{[]
  system "mkdir -p ",FIXDIR;
  (`$":",FIXDIR,"/peer.q") 0: ("got:()";".servers.autodiscovery:{got::got,enlist`autodiscovery}";".servers.procupdate:{got::got,enlist x}");
  PORTA::pickport 30000+`int$.z.i mod 20000;
  PORTB::pickport PORTA+1;
  };

spawnpeers:{[]
  {system QBIN," ",FIXDIR,"/peer.q -p ",(string x)," -q </dev/null >/dev/null 2>&1 &"} each PORTA,PORTB;
  if[not all waitlisten each PORTA,PORTB;'"test: peers failed to listen"];
  hA::hopen (`$":localhost:",string PORTA;2000);
  hB::hopen (`$":localhost:",string PORTB;2000);
  };

teardownfixture:{[] {@[{(neg x)"exit 0";(neg x)[]};x;()]} each hA,hB; system "sleep 0.3"; system "rm -rf ",FIXDIR;};
