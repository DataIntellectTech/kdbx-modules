/ mocks and fixture helpers for di.torq.proc.compression's tests.
/ Calls setenv, so run this module's tests in their own q session.

calls:([]lvl:`symbol$();ctx:`symbol$();msg:())

resetcalls:{[] `calls set ([]lvl:`symbol$();ctx:`symbol$();msg:()); }

mocklogfn:{[lvl;ctx;msg] `calls insert (lvl;ctx;msg); }

mockdeps:{[] (enlist`log)!enlist `info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;])}

FIXTUREDIR:"/tmp/di_compression_k4unit_fixture"

/ partitions relative to today, so the fixture never ages out of the maxage window
PARTS:.z.D-1 2
/ outside the window, to prove maxage excludes it
OLD:.z.D-400

/ build the fixture hdb. 200000 rows because kdb will not compress a file below the block size,
/ so a token few would make a no-op indistinguishable from a failure.
setupfixture:{[]
  system "rm -rf ",FIXTUREDIR;
  system "mkdir -p ",FIXTUREDIR,"/appconfig";
  d:`$":",FIXTUREDIR,"/hdb";
  {[d;dt] t:([]sym:200000?`A`B`C;price:200000?100f;size:200000?1000j);
    (` sv (`$string[d],"/",string[dt]),`trade`) set .Q.en[d] t;
    }[d;] each PARTS,OLD;
  writevalidcsv[];
  setenv[`TORQXAPPHOME;FIXTUREDIR];
  setenv[`TORQXDATAHOME;FIXTUREDIR];
  setenv[`TORQXAPPCONFIG;FIXTUREDIR,"/appconfig"];
  }

/ csv bodies live here, not inline in test.csv, whose reader would split on their commas
writecsv:{[s] (hsym `$FIXTUREDIR,"/appconfig/compressionconfig.csv") 0: enlist s; }

/ gzip (algo 2), block 17, level 5, at any age
writevalidcsv:{[]
  writecsv "table,minage,column,calgo,cblocksize,clevel\ntrade,0,price,2,17,5";
  }

/ an algo outside kdb's supported set
writebadalgocsv:{[]
  writecsv "table,minage,column,calgo,cblocksize,clevel\ntrade,0,price,99,17,5";
  }

teardownfixture:{[] system "rm -rf ",FIXTUREDIR; }

/ is a column file stored compressed? an empty -21! dict means it is not
compressed:{[dt;col] 0<count -21! hsym `$FIXTUREDIR,"/hdb/",(string dt),"/trade/",string col}

/ the last init log line, so the code defaults can be asserted
initlog:{[] last exec msg from calls where lvl=`info, ctx=`init}

/ the shipped framework defaults, read from the settings file itself
shippeddefaults:{[] (use`di.torq.config)[`parsefile] "di/torq/settings/compression.q"}

/ config builders - factored out so test.csv rows never need a raw comma
basecfg:{[] `csvpath`hdbpath`maxage`exitonfinish!(`$":",FIXTUREDIR,"/appconfig/compressionconfig.csv";`$":",FIXTUREDIR,"/hdb";365;0b)}

/ maxage and exitonfinish omitted, so the code defaults apply
nodefaultscfg:{[] `csvpath`hdbpath!(`$":",FIXTUREDIR,"/appconfig/compressionconfig.csv";`$":",FIXTUREDIR,"/hdb")}

/ an hdb path that does not exist
badhdbcfg:{[] `csvpath`hdbpath`exitonfinish!(`$":",FIXTUREDIR,"/appconfig/compressionconfig.csv";`:/tmp/di_compression_no_such_hdb;0b)}

/ values as a .toml settings file delivers them - strings for paths, text for the scalars
tomlcfg:{[] `csvpath`hdbpath`maxage`exitonfinish!(FIXTUREDIR,"/appconfig/compressionconfig.csv";FIXTUREDIR,"/hdb";"365";"false")}

/ a boolean setting that is neither true/false nor 1/0
badboolcfg:{[] `csvpath`hdbpath`exitonfinish!(`$":",FIXTUREDIR,"/appconfig/compressionconfig.csv";`$":",FIXTUREDIR,"/hdb";"yes")}

/ a csvpath that does not exist, so resolvecsv falls back to the framework's shipped csv
nocsvcfg:{[] `csvpath`hdbpath`exitonfinish!(`:no/such/compressionconfig.csv;`$":",FIXTUREDIR,"/hdb";0b)}
