/ mock log dependency and fixture helpers, loaded from the repo root; sets TORQXAPPHOME so run in its own q session

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

/ config-dict builders
absdircfg:{[] (enlist`dir)!enlist `$":",FIXTUREDIR}
reldircfg:{[] (enlist`dir)!enlist `:di_hdb_k4unit_fixture}

/ as absdircfg but with dir as a string, as from .toml settings
absdirstringcfg:{[] (enlist`dir)!enlist ":",FIXTUREDIR}
