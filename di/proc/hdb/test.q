/ shared mock log dependency + fixture helpers for di.proc.hdb's tests.
/ Assumes q is started with the TorqX repo root as the working directory.
/ NOTE: this test calls setenv[`TORQXAPPHOME;...] - run di.proc.hdb's tests in their own
/ fresh q session, not interleaved with other modules' tests in one shared process.

calls:([]lvl:`symbol$();ctx:`symbol$();msg:())

resetcalls:{[] `calls set ([]lvl:`symbol$();ctx:`symbol$();msg:()); }

mocklogfn:{[lvl;ctx;msg] `calls insert (lvl;ctx;msg); }

mockdeps:{[] enlist[`log]!enlist `info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;])}

FIXTUREDIR:"/tmp/di_hdb_k4unit_fixture"

/ a trivial "database directory" - just a serialized table, the simplest thing \l can load
setupfixture:{[]
  system "rm -rf ",FIXTUREDIR;
  system "mkdir -p ",FIXTUREDIR;
  (hsym `$FIXTUREDIR,"/widgets") set ([]id:1 2 3;name:`a`b`c);
  }

teardownfixture:{[] system "rm -rf ",FIXTUREDIR; }

/ config-dict builders - factored out so test.csv rows never need a raw "," (q string
/ concatenation) inline, which gets misread as a CSV field separator unless the whole
/ field is quoted-and-escaped. Simpler to just keep commas out of the CSV entirely.
absdircfg:{[] (enlist`dir)!enlist `$":",FIXTUREDIR}
reldircfg:{[] (enlist`dir)!enlist `:di_hdb_k4unit_fixture}

/ same as absdircfg, but dir is a plain q STRING rather than a symbol - simulates a
/ .toml-sourced settings value (di.util.toml has no symbol type, see di/config's TOML
/ integration). resolvedir must normalize this itself; `string`/`1_string` throw
/ 'type on an already-string input, which is exactly the bug this covers.
absdirstringcfg:{[] (enlist`dir)!enlist ":",FIXTUREDIR}
