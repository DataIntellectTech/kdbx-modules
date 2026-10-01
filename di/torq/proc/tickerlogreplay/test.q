/ test helpers: each replay runs in a fresh q, as the replay process exits when complete

FIXDIR:"/tmp/ditlrtest"
QBIN:first system "readlink -f /proc/",(string .z.i),"/exe"
D:"2026.10.01"
fp:{[x] hsym`$FIXDIR,"/",x}
/ q source for a fixture path
hp:{[x] "`$\":",FIXDIR,"/",x,"\""}

/ run a q script in a fresh q; returns its exit code
runq:{[lines] fp["run.q"] 0: lines; "J"$last system QBIN," ",FIXDIR,"/run.q -q </dev/null >",FIXDIR,"/run.log 2>&1; echo $?"}
/ replay with q lines run before use and a config from a q expression; an init error exits 3
replayp:{[pre;cfg] runq(
  enlist["lg:`info`warn`error!({[c;m] -1 \"I \",string[c],\": \",m};{[c;m] -1 \"W \",string[c],\": \",m};{[c;m] -1 \"E \",string[c],\": \",m})"],pre,(
  "r:use`di.torq.proc.tickerlogreplay";
  "@[r.init[;enlist[`log]!enlist lg];",cfg,";{-1 \"ERR \",x;exit 3}]";
  "exit 0"))}
replay:replayp[()]
/ replay settings for the plain log, with overrides
plain:{[x] "(`schemafile`hdbdir`tplogfile`segmentedmode!(`$\"",FIXDIR,"/schema.q\";`$\":",FIXDIR,"/hdb\";`$\":",FIXDIR,"/tplog",D,"\";0b)),",x}
sect:{[x] "enlist[`replay]!enlist ",x}
ran:{[x] read0 fp"run.log"}
logged:{[s] any ran[] like s}
/ was a log named in the list of logs to replay
replayed:{[s] any (ran[] where ran[] like "*Replaying the following log*") like "*",s,"*"}

/ an hdb table, or () if absent
hdb:{[p;t] @[get;fp"hdb/",p,"/",string[t],"/";()]}
rows:{[p;t] count hdb[p;t]}
syms:{[p;t] (get fp"hdb/sym") hdb[p;t]`sym}
clearhdb:{system "rm -rf ",FIXDIR,"/hdb ",FIXDIR,"/tmp"}

setupfixture:{[]
  system "rm -rf ",FIXDIR; system "mkdir -p ",FIXDIR;
  fp["schema.q"] 0: (
    "trade:([]time:`timestamp$();sym:`g#`symbol$();price:`float$();size:`int$())";
    "quote:([]time:`timestamp$();sym:`g#`symbol$();bid:`float$())");
  / plain log: trade b a, quote a, trade c
  h:hopen fp["tplog",D] set ();
  h enlist(`upd;`trade;(2026.10.01D10:00:00 2026.10.01D10:00:01;`b`a;1 2f;10 20i));
  h enlist(`upd;`quote;(enlist 2026.10.01D10:00:02;enlist`a;enlist 3f));
  h enlist(`upd;`trade;(enlist 2026.10.01D10:00:03;enlist`c;enlist 4f;enlist 40i));
  hclose h;
  / a sort csv sorting trade by time only, with no attributes
  fp["timesort.csv"] 0: ("tabname,att,column,sort";"default,,time,1");
  / segmented logs written by a segmentedtp process
  runq(
    "nolog:`info`warn`error!3#{[c;m]}";
    "h:use`di.torq.handlers";
    "h.init enlist[`log]!enlist nolog";
    "seg:use`di.torq.proc.segmentedtp";
    "seg.init[`proctype`procname`schemafile`stplg!(`segmentedtp;`stp1;\"",FIXDIR,"/schema.q\";enlist[`kdbtplog]!enlist`$\"",FIXDIR,"/stp\");`log`timer`handlers!(nolog;enlist[`addjob]!enlist {[a;b;c;d;e;f]};`register`remove`list#h)]";
    ".u.upd[`trade;(`b`a;1 2f;10 20i)]";
    ".u.upd[`quote;(enlist`a;enlist 3f)]";
    ".u.upd[`trade;(enlist`c;enlist 4f;enlist 40i)]";
    "exit 0");
  `STPDIR`SD set' (FIXDIR,"/stp/",string first key fp"stp";string .z.d);
  / a meta table naming logs from two dates
  system "mkdir -p ",FIXDIR,"/mixed";
  fp["mixed/stpmeta"] set ([]seq:0 1i;logname:fp each ("mixed/stp1_trade20261001000000";"mixed/stp1_quote20261002000000");start:2#.z.p;end:2#0Np;tbls:(enlist`trade;enlist`quote);msgcount:2#0i;schema:(();());additional:(();()));
  }

/ replay settings for the segmentedtp logs, with overrides
seg:{[x] "(`schemafile`hdbdir`tplogdir!(`$\"",FIXDIR,"/schema.q\";`$\":",FIXDIR,"/hdb\";`$\":",STPDIR,"\")),",x}

teardownfixture:{[] system "rm -rf ",FIXDIR}
