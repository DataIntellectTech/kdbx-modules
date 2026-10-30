/ shared mock dependencies + fixture helpers for di.torq.proc.compression's tests.
/ Assumes q is started with the repo root as the working directory.
/ NOTE: this test calls setenv, so run di.torq.proc.compression's tests in their own fresh q
/ session, not interleaved with other modules' tests in one shared process.

calls:([]lvl:`symbol$();ctx:`symbol$();msg:())

resetcalls:{[] `calls set ([]lvl:`symbol$();ctx:`symbol$();msg:()); }

mocklogfn:{[lvl;ctx;msg] `calls insert (lvl;ctx;msg); }

mockdeps:{[] (enlist`log)!enlist `info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;])}

FIXTUREDIR:"/tmp/di_compression_k4unit_fixture"

/ a two-partition hdb with a column big enough to be worth compressing. kdb will not compress a
/ file smaller than its block size, so a handful of rows would leave the test asserting on a
/ no-op that looks identical to a failure - hence 200000 rows rather than a token few.
setupfixture:{[]
  system "rm -rf ",FIXTUREDIR;
  system "mkdir -p ",FIXTUREDIR,"/appconfig";
  d:`$":",FIXTUREDIR,"/hdb";
  {[d;dt] t:([]sym:200000?`A`B`C;price:200000?100f;size:200000?1000j);
    (` sv (`$string[d],"/",string[dt]),`trade`) set .Q.en[d] t;
    }[d;] each 2026.01.01 2026.01.02;
  writevalidcsv[];
  setenv[`TORQXAPPHOME;FIXTUREDIR];
  setenv[`TORQXDATAHOME;FIXTUREDIR];
  setenv[`TORQXAPPCONFIG;FIXTUREDIR,"/appconfig"];
  }

/ the compression config csv lives here as a named helper rather than inline in test.csv, whose
/ own reader would take the commas as field separators.
writecsv:{[s] (hsym `$FIXTUREDIR,"/appconfig/compressionconfig.csv") 0: enlist s; }

/ compress every trade column with gzip (algo 2), block 17, level 5, at any age
writevalidcsv:{[]
  writecsv "table,minage,column,calgo,cblocksize,clevel\ntrade,0,price,2,17,5";
  }

/ an algo outside kdb's supported set - di.compression's own checkcsv must reject it
writebadalgocsv:{[]
  writecsv "table,minage,column,calgo,cblocksize,clevel\ntrade,0,price,99,17,5";
  }

teardownfixture:{[] system "rm -rf ",FIXTUREDIR; }

/ kdb reports a file's compression with -21!: an empty dict means stored uncompressed.
compressed:{[dt;col] 0<count -21! hsym `$FIXTUREDIR,"/hdb/",(string dt),"/trade/",string col}

/ the shipped framework defaults, read from the settings file itself - that file is the only
/ place a default lives, so it is what a test has to assert against.
shippeddefaults:{[] (use`di.torq.config)[`parsefile] "di/torq/settings/compression.q"}

/ config-dict builders - factored out so test.csv rows never need a raw "," inline.
basecfg:{[] `csvpath`hdbpath`maxage`exitonfinish!(`$":",FIXTUREDIR,"/appconfig/compressionconfig.csv";`$":",FIXTUREDIR,"/hdb";365;0b)}

/ exitonfinish omitted, to prove the code default is applied and matches the settings file
nodefaultscfg:{[] `csvpath`hdbpath!(`$":",FIXTUREDIR,"/appconfig/compressionconfig.csv";`$":",FIXTUREDIR,"/hdb")}

/ an hdb path that does not exist - init must refuse rather than report a zero-column success
badhdbcfg:{[] `csvpath`hdbpath`exitonfinish!(`$":",FIXTUREDIR,"/appconfig/compressionconfig.csv";`:/tmp/di_compression_no_such_hdb;0b)}

/ .toml delivers strings and longs where a .q settings file delivers typed values
tomlcfg:{[] `csvpath`hdbpath`maxage`exitonfinish!(FIXTUREDIR,"/appconfig/compressionconfig.csv";FIXTUREDIR,"/hdb";365;0b)}
