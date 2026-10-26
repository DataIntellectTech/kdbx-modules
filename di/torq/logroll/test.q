/ mock deps and fixture helpers, loaded by both the k4unit process and spawned children

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

/ config-dict builders
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

/ enabled cases run logroll.init in a separate child process and assert on the files it leaves
qbinary:{[] c:getenv[`QCMD]; $[0=count c;"q";c]}
/ run the child via sh -c with stdin from /dev/null so it is non-interactive
spawnchildinit:{[cfgname]
  system "sh -c \"cd ",getenv[`TORQXHOME]," && ",qbinary[]," di/torq/logroll/test_childinit.q -cfg ",cfgname," -resultdir ",FIXTUREDIR," < /dev/null\"";
  }

/ the child's saved addjobcalls
loadchildaddjobcalls:{[] get hsym `$FIXTUREDIR,"/addjobcalls_result"}
addjobcount:{[] count loadchildaddjobcalls[]}
addjobperiod:{[] first loadchildaddjobcalls[]`period}
addjobmode:{[] first loadchildaddjobcalls[]`mode}
addjobhasstartattime:{[] `startattime in key first loadchildaddjobcalls[]`opts}

resolveabssymbolok:{[] "/tmp/absprobe"~logroll.resolvedir[`:/tmp/absprobe]}
resolveabsstringok:{[] "/tmp/absprobe"~logroll.resolvedir["/tmp/absprobe"]}
resolverelstringok:{[] (getenv[`TORQXAPPHOME],"/relprobe")~logroll.resolvedir["relprobe"]}
