/ shared mock deps + fixture helpers for di.torq.logroll's tests.
/ NOTE: this file is loaded by both the k4unit parent process AND the throwaway
/ child process spawned by spawnchildinit below (see test_childinit.q) - each gets
/ its own independent copy of everything defined here. Run di.torq.logroll's tests in
/ their own fresh q session, not interleaved with other modules' tests in one
/ shared process (same convention as di.proc.hdb's tests).

calls:([]lvl:`symbol$();ctx:`symbol$();msg:())
resetcalls:{[] `calls set ([]lvl:`symbol$();ctx:`symbol$();msg:()); }
mocklogfn:{[lvl;ctx;msg] `calls insert (lvl;ctx;msg); }
mocklog:{[] `info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;])}

addjobcalls:([]id:`symbol$();func:();params:();period:();mode:`short$();opts:())
mockaddjob:{[id;func;params;period;mode;opts] `addjobcalls insert (id;func;params;period;mode;opts); }

mockdeps:{[] `log`timer!(mocklog[];enlist[`addjob]!enlist mockaddjob)}

FIXTUREDIR:"/tmp/di_logroll_k4unit_fixture"
RELFIXTUREDIR:"/tmp/di_logroll_k4unit_relfixture"

setupfixture:{[]
  system "rm -rf ",FIXTUREDIR;
  system "mkdir -p ",FIXTUREDIR;
  system "rm -rf ",RELFIXTUREDIR;
  }

teardownfixture:{[]
  system "rm -rf ",FIXTUREDIR;
  system "rm -rf ",RELFIXTUREDIR;
  }

/ config-dict builders - factored out so test.csv rows never need a raw "," inline
/ (see di/proc/hdb/test.q's absdircfg/reldircfg for the same reasoning).
nosectioncfg:{[] (enlist`procname)!enlist `testproc}
disabledcfg:{[] `procname`logroll!(`testproc;(enlist`enabled)!enlist 0b)}
enabledabsdircfg:{[] `procname`logroll!(`testproc;`enabled`dir!(1b;FIXTUREDIR))}
enabledreldircfg:{[] `procname`logroll!(`testproc;`enabled`dir!(1b;"di_logroll_k4unit_relfixture"))}
enabledsuppressaliascfg:{[] `procname`logroll!(`testproc;`enabled`dir`suppressalias!(1b;FIXTUREDIR;1b))}

listfiles:{[dir] key hsym `$dir}
outfilecount:{[] sum listfiles[FIXTUREDIR] like "out_testproc_*.log"}
errfilecount:{[] sum listfiles[FIXTUREDIR] like "err_testproc_*.log"}
outaliasexists:{[] `out_testproc.log in listfiles[FIXTUREDIR]}
erraliasexists:{[] `err_testproc.log in listfiles[FIXTUREDIR]}
relfilecount:{[] sum listfiles[RELFIXTUREDIR] like "out_testproc_*.log"}

/ calling logroll.init directly in THIS process would reassign the k4unit test
/ runner's own fd 1/2 the moment it's enabled - confirmed empirically to corrupt
/ k4unit's own result reporting (it does its own stdout instrumentation per test).
/ So the "enabled" cases spawn test_childinit.q as a genuine separate process
/ instead (same precedent di/torq/servers/test.q uses for its own self-connect case) -
/ this process's own output is never touched, and results are asserted purely by
/ inspecting files the child process left behind on disk.
qbinary:{[] c:getenv[`QCMD]; $[0=count c;"q";c]}
/ this kdb-x build's `system` execs a bare command directly rather than routing it
/ through a shell - `cd x && y` fails with "No such file or directory" trying to
/ exec the literal string "cd" (confirmed empirically). Wrapping the whole pipeline
/ as a single `sh -c "..."` argument works, since that's one exec of the real `sh`
/ binary which then does its own shell-syntax parsing internally.
/ NB `< /dev/null` detaches the child's stdin from any inherited TTY, so the child is a
/ non-interactive (background-like) launch regardless of how THIS test runner was started. That
/ matches how logroll is really used (nohup/systemd), and is required now that logroll skips the
/ redirect for interactive TTY sessions (see logroll.q interactive[]) - without it, running the
/ suite from a terminal would leave the children on a TTY and they would (correctly) skip the
/ redirect, so the "files created" assertions would fail.
spawnchildinit:{[cfgname]
  system "sh -c \"cd ",getenv[`TORQXHOME]," && ",qbinary[]," di/torq/logroll/test_childinit.q -cfg ",cfgname," -resultdir ",FIXTUREDIR," < /dev/null\"";
  }

/ the child serializes its own addjobcalls table to disk before exiting (its
/ in-memory table is gone the moment the process exits) - load it back here.
loadchildaddjobcalls:{[] get hsym `$FIXTUREDIR,"/addjobcalls_result"}
addjobcount:{[] count loadchildaddjobcalls[]}
addjobperiod:{[] first loadchildaddjobcalls[]`period}
addjobmode:{[] first loadchildaddjobcalls[]`mode}
addjobhasstartattime:{[] `startattime in key first loadchildaddjobcalls[]`opts}

/ factored into helpers (not inline in test.csv) - a code field that starts with a
/ literal `"` confuses the CSV reader into treating it as a quoted field and
/ mishandling whatever follows the closing quote (same bug class noted in
/ di/proc/hdb/test.q and project memory).
resolveabssymbolok:{[] "/tmp/absprobe"~logroll.resolvedir[`:/tmp/absprobe]}
resolveabsstringok:{[] "/tmp/absprobe"~logroll.resolvedir["/tmp/absprobe"]}
resolverelstringok:{[] (getenv[`TORQXAPPHOME],"/relprobe")~logroll.resolvedir["relprobe"]}
