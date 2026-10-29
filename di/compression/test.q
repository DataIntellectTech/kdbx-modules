/ fixture helpers for di.compression's worker-process and single-file tests. Assumes cwd is the kdbx-modules repo root.
/ two real worker q processes on ephemeral ports serve peach with \s -2; each writes its port to a file.

WDIR:"cmpWorkers_",string .z.i;
WPORTS:();
WH:();

/ a one-partition hdb with two tables of three columns, and a csv that gzips everything
mkworkerhdb:{[]
  d:hsym`$WDIR,"/hdb";
  {[d;t] (` sv .Q.par[d;2026.01.01;t],`) set .Q.en[d;([]time:2026.01.01D0+til 1000;sym:1000?`a`b`c;price:1000?100f)]}[d] each `trade`quote;
  (hsym`$WDIR,"/params.csv") 0: ("table,minage,column,calgo,cblocksize,clevel";"default,0,default,2,17,6");
  };

/ the port files the workers have written
portfiles:{[] ` sv/: (hsym`$WDIR),/:k where (k:key hsym`$WDIR) like "port_*"};

/ start two workers with di.compression loaded and wait for their ports
startworkers:{[]
  system "mkdir -p ",WDIR;
  (hsym`$WDIR,"/worker.q") 0: (
    "cmp:use`di.compression;";
    "cmp.init enlist[`log]!enlist `info`warn`error!3#enlist {[c;m]};";
    "(hsym`$\"",WDIR,"/port_\",string .z.i) 0: enlist string system\"p\";");
  {[x] system "sleep 120 | ",(first .z.X)," ",WDIR,"/worker.q -p 0W -q >/dev/null 2>&1 &"} each 1 2;
  / wait up to 10s for both port files
  {[x] system "sleep 0.1"; x+1}/[{(x<100) and 2>count portfiles[]};0];
  `WPORTS set "J"$first each read0 each portfiles[];
  `WH set hopen each WPORTS;
  };

/ compress the hdb with \s -2 over the workers, counting cleancompressed calls on this process
CLEANS:0;
workerrun:{[]
  mkworkerhdb[];
  orig:.m.di.0compression.cleancompressed;
  .m.di.0compression.cleancompressed:{[o;f;a] @[`.;`CLEANS;+;1]; o[f;a]}[orig];
  .z.pd:{`u#WH};
  system "s -2";
  r:@[{cmp.docompression[hsym`$WDIR,"/hdb";hsym`$WDIR,"/params.csv"];`ok};::;{x}];
  system "s 0";
  .m.di.0compression.cleancompressed:orig;
  f:raze {p:.Q.par[hsym`$WDIR,"/hdb";2026.01.01;x]; ` sv/: p,/:key[p] except `.d} each `trade`quote;
  `result`mainclean`algos`stats!(r;CLEANS;{(-21!x)`algorithm} each f;count cmp.getstatstab[])
  };

stopworkers:{[]
  {neg[x] "exit 0"; neg[x][]} each WH;
  system "rm -rf ",WDIR;
  };

/ the single-file compress legacy housekeeping's kdbzip calls: .cmp.compress[f;2;17;4;hcount f] (housekeeping.q:64)
onefile:{[]
  f:hsym`$WDIR,"_one";
  f set v:100000?100f;
  cmp.compress[f;2;17;4;hcount f];
  t:hsym`$(string f),"_kdbtempzip";
  r:`original`temp`same!(0=count -21!f;2 17 4i~(-21!t)`algorithm`logicalBlockSize`zipLevel;v~get t);
  hdel each (f;t);
  r
  };
