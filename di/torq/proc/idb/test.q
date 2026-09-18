/ shared mock log dependency + fixture helpers for di.torq.proc.idb's tests.
/ Assumes q is started with the TorqX repo root as the working directory.
/ NOTE: this test calls setenv[`TORQXAPPHOME;...] - run di.torq.proc.idb's tests in their own
/ fresh q session, not interleaved with other modules' tests in one shared process.

calls:([]lvl:`symbol$();ctx:`symbol$();msg:())

resetcalls:{[] `calls set ([]lvl:`symbol$();ctx:`symbol$();msg:()); }

mocklogfn:{[lvl;ctx;msg] `calls insert (lvl;ctx;msg); }

/ the servers mock stands in for a reachable wdb: waitfortype succeeds and gethandlebytype hands
/ back a handle that answers .wdb.getparams[] with WDBPARAMS
LASTQ:();
WAITOK:1b;
scalls:([]fn:`symbol$();arg:());
mockstartup:{[c] `scalls set scalls upsert `fn`arg!(`startup;c);};
mockwait:{[pt;t;p] `scalls set scalls upsert `fn`arg!(`waitfortype;pt); WAITOK};
/ the handle EVALUATES the query, as a real wdb would, against the .wdb.* variables set below -
/ so the test exercises the parse tree the idb actually builds rather than a canned answer
mockhandle:{[pt;sel] `scalls set scalls upsert `fn`arg!(`gethandlebytype;pt); {[q] `LASTQ set q; value q}};
mockgetservers:{[pt] ([]w:`int$())};
mockservers:{[] `startup`getservers`gethandlebytype`waitfortype!(mockstartup;mockgetservers;mockhandle;mockwait)}

mockdeps:{[] `log`servers!(`info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;]);mockservers[])}

/ the root variables a real wdb publishes, which the evaluated query reads
setwdb:{[sd] set[`.wdb.savedir;sd]; set[`.wdb.hdbdir;hsym `$FIXTUREHDBDIR]; set[`.wdb.currentpartition;TESTDATE];}
setwdbparams:{[] setwdb hsym `$FIXTUREDIR;}

/ the wdb reports a savedir that is not on disk - the window before its first flush
setwdbmissingdir:{[] setwdb `:/tmp/di_idb_k4unit_no_such_dir;}

/ a wdb that does not publish one of them - an older build, say
dropwdbvar:{[v] ![`.wdb;();0b;enlist v];}

askedwdb:{[] `waitfortype in exec fn from scalls}

/ the query the idb actually sent, captured by the mock handle
askedforvars:{[] LASTQ~(each;value;`.wdb.savedir`.wdb.hdbdir`.wdb.currentpartition)}
resetservercalls:{[] `scalls set ([]fn:`symbol$();arg:()); `WAITOK set 1b; `LASTQ set ();}

FIXTUREDIR:"/tmp/di_idb_k4unit_fixture"
FIXTUREHDBDIR:"/tmp/di_idb_k4unit_hdb_fixture"
TESTDATE:2020.01.01

/ a trivial partitioned "database directory" - two dated partitions, to prove the root mount
/ sees both without being told a date. `name` is
/ genuinely enumerated (via .Q.en, against a fresh FIXTUREHDBDIR/sym - mirrors how the real
/ wdb enumerates against hdbdir, not savedir) so tests can assert it actually resolves to
/ real symbols, not raw indices - that's the exact failure mode loadsym[] exists to prevent.
setupfixture:{[]
  system "rm -rf ",FIXTUREHDBDIR;
  system "mkdir -p ",FIXTUREHDBDIR;
  widgets:.Q.en[hsym `$FIXTUREHDBDIR;([]id:1 2 3;name:`a`b`c)];
  system "rm -rf ",FIXTUREDIR;
  system "mkdir -p ",FIXTUREDIR,"/",string TESTDATE;
  / trailing `sv (path;`) matches di.torq.proc.wdb's own flushtable path construction - a bare
  / `:dir/widgets` (no trailing slash) serialises as ONE flat file instead of splaying to a
  / directory, which throws 'type on mount for an enumerated column (caught by direct testing,
  / not by reading the code: the same mistake here silently "worked" with the OLD, non-enumerated
  / fixture, since a flat-file table loads back fine when nothing on it is enum-typed).
  (` sv (hsym `$FIXTUREDIR,"/",(string TESTDATE),"/widgets";`)) set widgets;
  system "mkdir -p ",FIXTUREDIR,"/",string .z.d;
  (` sv (hsym `$FIXTUREDIR,"/",(string .z.d),"/widgets";`)) set widgets;
  }

teardownfixture:{[] system "rm -rf ",FIXTUREDIR; system "rm -rf ",FIXTUREHDBDIR; }

/ config-dict builders - factored out so test.csv rows never need a raw "," (q string
/ concatenation) inline, which gets misread as a CSV field separator unless the whole
/ field is quoted-and-escaped. Simpler to just keep commas out of the CSV entirely.
/ the idb takes savedir/hdbdir from the wdb, so config carries neither. setwdbparams decides
/ what the mock wdb reports.
cfg:{[] (enlist`wdbtypes)!enlist `wdb}

/ config that still (wrongly) sets the dirs - init must ignore them and warn
stalecfg:{[] `wdbtypes`savedir`hdbdir!(`wdb;`$":",FIXTUREDIR;`$":",FIXTUREHDBDIR)}

/ savedir and hdbdir as plain q STRINGS - simulates .toml-sourced settings
/ (di.util.toml has no symbol/date type, see di/torq/proc/hdb's identical concern).
/ resolvedatadir/"D"$ must normalize these themselves.

/ no `savedir` at all - init must error before looking at hdbdir

/ savedir present, no `hdbdir` at all

/ a savedir that does not exist - the window before the wdb's first flush creates it.
/ init/reload must warn, not throw.

/ --- sym-file change detection (legacy TorQ's symfilehaschanged) ---

/ an unchanged sym file is silent, so a skip is proven by the absence of the entry log
symattempted:{[] 0<count select from calls where lvl=`info,msg like "loading the sym file*"}
symreloaded:{[] 0<count select from calls where lvl=`info,msg like "loaded sym domain*"}
symfailed:{[] 0<count select from calls where lvl=`error,msg like "failed to load sym file*"}

/ .Q.en with an unseen symbol rewrites FIXTUREHDBDIR/sym, making it strictly bigger
growsym:{[s] .Q.en[hsym `$FIXTUREHDBDIR;([]id:enlist 0;name:enlist s)];}

/ no sym file yet - the startup window legacy TorQ cannot reach, since its idb blocks on a wdb
setupnosymfixture:{[]
  system "rm -rf ",FIXTUREDIR;
  system "rm -rf ",FIXTUREHDBDIR;
  system "mkdir -p ",FIXTUREHDBDIR;
  system "mkdir -p ",FIXTUREDIR,"/",string TESTDATE;
  }

/ the first wdb flush creates hdbdir/sym
createsymfile:{[] .Q.en[hsym `$FIXTUREHDBDIR;([]id:1 2 3;name:`a`b`c)];}

/ a sym file that exists but cannot be read back as a symbol vector - load signals on it, so the
/ size is never recorded and the next reload must try again
corruptsymfile:{[] (hsym `$FIXTUREHDBDIR,"/sym") 0: enlist "not a serialised symbol vector";}

/ the partition the module recorded. Not exposed by the module (nothing consumes it), so the tests
/ reach into its private namespace rather than the module inventing an accessor for their benefit.
recordedpartition:{[] get `.m.di.0torq.0proc.0idb.partition}
