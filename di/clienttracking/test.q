/ test helpers: server peers running di.clienttracking under different settings

FIXDIR:"/tmp/dictracktest"
QBIN:first system "readlink -f /proc/",(string .z.i),"/exe"
isfree:{[p] not @[{hclose hopen x;1b};(`$":localhost:",string p;100);0b]}
waitlisten:{[p] d:.z.p+0D00:00:05; while[(.z.p<d) and isfree p; system "sleep 0.05"]; not isfree p}
peer:{[p] hopen `$":localhost:",string p}
PORTS:`a`b`c`d!4#0N

/ a: defaults; b: opencloseonly; c: disabled; d: INTRUSIVE with a 1s MAXIDLE and RETAIN
CFGS:`a`b`c`d!("()!()";"enlist[`opencloseonly]!enlist 1b";"enlist[`enabled]!enlist 0b";"`INTRUSIVE`MAXIDLE`RETAIN!(1b;`long$0D00:00:01;`long$0D00:00:01)")

setupfixture:{[]
  system "rm -rf ",FIXDIR; system "mkdir -p ",FIXDIR;
  {[n;c] (`$":",FIXDIR,"/",string[n],".q") 0: (
    "h:use`di.torq.handlers";
    "h.init enlist[`log]!enlist `info`warn`error!3#{[c;m]}";
    "ct:use`di.clienttracking";
    "ct.init[enlist[`clients]!enlist ",c,";enlist[`handlers]!enlist `register`remove`list#h]")}'[key CFGS;value CFGS];
  p:40000+(`int$.z.i mod 20000)+til 500; p:p where isfree each p;
  PORTS::key[PORTS]!4#p;
  {system QBIN," ",FIXDIR,"/",string[x],".q -p ",(string y)," -q </dev/null >/dev/null 2>&1 &"}'[key PORTS;value PORTS];
  if[not all waitlisten each value PORTS;'"test: peers failed to listen"];
  }

/ one field of this connection's row on the server
mine:{[h;c] h"exec first ",c," from .clients.clients where w=.z.w"}

teardownfixture:{[] {@[{h:peer x;(neg h)"exit 0";(neg h)[]};x;()]} each value PORTS; system "sleep 0.3"; system "rm -rf ",FIXDIR;}
