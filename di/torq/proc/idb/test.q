/ shared mock log dependency + fixture helpers for di.torq.proc.idb's tests.
/ Assumes q is started with the TorqX repo root as the working directory.
/ NOTE: this test calls setenv[`TORQXAPPHOME;...] - run di.torq.proc.idb's tests in their own
/ fresh q session, not interleaved with other modules' tests in one shared process.

calls:([]lvl:`symbol$();ctx:`symbol$();msg:())

resetcalls:{[] `calls set ([]lvl:`symbol$();ctx:`symbol$();msg:()); }

mocklogfn:{[lvl;ctx;msg] `calls insert (lvl;ctx;msg); }

mockdeps:{[] enlist[`log]!enlist `info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;])}

FIXTUREDIR:"/tmp/di_idb_k4unit_fixture"
FIXTUREHDBDIR:"/tmp/di_idb_k4unit_hdb_fixture"
TESTDATE:2020.01.01

/ a trivial "database directory" - a fixed-date partition (for the `partition` override
/ tests) plus a today-dated one (for the default, no-override -> .z.d test). `name` is
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
absdircfg:{[] `savedir`hdbdir`partition!(`$":",FIXTUREDIR;`$":",FIXTUREHDBDIR;TESTDATE)}
reldircfg:{[] `savedir`hdbdir`partition!(`:di_idb_k4unit_fixture;`$":",FIXTUREHDBDIR;TESTDATE)}

/ savedir, hdbdir AND partition all as plain q STRINGS - simulates .toml-sourced settings
/ (di.util.toml has no symbol/date type, see di/torq/proc/hdb's identical concern).
/ resolvedatadir/"D"$ must normalize these themselves.
absdirstringcfg:{[] `savedir`hdbdir`partition!(":",FIXTUREDIR;":",FIXTUREHDBDIR;string TESTDATE)}

/ no `partition` override - init/reload must derive .z.d fresh each time
nopartitioncfg:{[] `savedir`hdbdir!(`$":",FIXTUREDIR;`$":",FIXTUREHDBDIR)}

/ no `savedir` at all - init must error before looking at hdbdir/partition
nosavedircfg:{[] (enlist`partition)!enlist TESTDATE}

/ savedir present, no `hdbdir` at all - init must error before looking at partition
nohdbdircfg:{[] `savedir`partition!(`$":",FIXTUREDIR;TESTDATE)}

/ a partition date with NO corresponding directory under FIXTUREDIR - simulates the window
/ right after a wdb EOD move (old day's dir just rm -rf'd) and before the new day's first
/ intraday flush recreates it. init/reload must warn, not throw.
MISSINGDATE:2019.01.01
missingpartitioncfg:{[] `savedir`hdbdir`partition!(`$":",FIXTUREDIR;`$":",FIXTUREHDBDIR;MISSINGDATE)}

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

/ root sym deliberately out of step with the file on disk - a union-merge would keep this order
/ and silently resolve every enum column wrongly
pollutesym:{[] @[`.;`sym;:;`x`y`a`b`c];}
symfilecontents:{[] get hsym `$FIXTUREHDBDIR,"/sym"}

/ a sym file that exists but cannot be read back as a symbol vector - load signals on it, so the
/ size is never recorded and the next reload must try again
corruptsymfile:{[] (hsym `$FIXTUREHDBDIR,"/sym") 0: enlist "not a serialised symbol vector";}
