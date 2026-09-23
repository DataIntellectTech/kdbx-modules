/ shared mock dependencies + fixture helpers for di.torq.proc.housekeeping's tests.
/ Assumes q is started with the repo root as the working directory.
/ NOTE: this test calls setenv, so run di.torq.proc.housekeeping's tests in their own fresh q
/ session, not interleaved with other modules' tests in one shared process.

calls:([]lvl:`symbol$();ctx:`symbol$();msg:())

resetcalls:{[] `calls set ([]lvl:`symbol$();ctx:`symbol$();msg:()); }

mocklogfn:{[lvl;ctx;msg] `calls insert (lvl;ctx;msg); }

/ mock timer: records what would have been scheduled instead of really scheduling it. Keeps the
/ tests independent of di.timer, and sidesteps its "id already exists" guard - several tests
/ init the module repeatedly in one session, which a real timer would reject on the second call.
scheduled:([]id:`symbol$();period:`int$();mode:`short$();opts:())

resetscheduled:{[] `scheduled set ([]id:`symbol$();period:`int$();mode:`short$();opts:()); }

mockaddjob:{[id;func;params;period;mode;opts] `scheduled insert (id;`int$period;`short$mode;opts); }

mockdeps:{[]
  `log`timer!(
    `info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;]);
    `addjob`deletejobs`enablejobs`disablejobs`getactivejobs!(mockaddjob;{[x]};{[x]};{[x]};{[]}))
  }

/ log-only deps, for asserting init errors when the timer dep is absent
logonlydeps:{[] (enlist`log)!enlist `info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;])}

FIXTUREDIR:"/tmp/di_housekeeping_k4unit_fixture"

/ a directory of files to clean up: two that every rule says should go, and three that each
/ trip a different exemption (wrong extension / too recent / explicitly excluded), so a single
/ run proves all four selection rules at once rather than only the positive case.
setupfixture:{[]
  system "rm -rf ",FIXTUREDIR;
  system "mkdir -p ",FIXTUREDIR,"/logs";
  system "touch -d '20 days ago' ",FIXTUREDIR,"/logs/old1.log ",FIXTUREDIR,"/logs/old2.log";
  system "touch -d '20 days ago' ",FIXTUREDIR,"/logs/keep.txt ",FIXTUREDIR,"/logs/excluded.log";
  system "touch ",FIXTUREDIR,"/logs/recent.log";
  / each remaining action gets its own directory so the tests can't disturb one another - the rm
  / test genuinely deletes its inputs, so sharing a directory would make test order significant
  system "mkdir -p ",FIXTUREDIR,"/gz";
  system "touch -d '20 days ago' ",FIXTUREDIR,"/gz/old1.log ",FIXTUREDIR,"/gz/old2.log";
  system "mkdir -p ",FIXTUREDIR,"/arch/olddir";
  system "touch -d '20 days ago' ",FIXTUREDIR,"/arch/olddir/content.txt";
  / the directory's own mtime is what find -type d -mtime tests, and writing a file inside it
  / bumps that back to now - so age the directory AFTER filling it, not before
  system "touch -d '20 days ago' ",FIXTUREDIR,"/arch/olddir";
  system "mkdir -p ",FIXTUREDIR,"/mins";
  system "touch -d '5 minutes ago' ",FIXTUREDIR,"/mins/stale.log";
  system "touch ",FIXTUREDIR,"/mins/justnow.log";
  / for the addaction test - a custom handler records rather than deletes, so this survives
  system "mkdir -p ",FIXTUREDIR,"/custom";
  system "touch -d '20 days ago' ",FIXTUREDIR,"/custom/target.dat";
  system "mkdir -p ",FIXTUREDIR,"/appconfig";
  writevalidcsv[];
  setenv[`DIHKFIXTURE;FIXTUREDIR];
  }

/ write the job csv the fixture config points at. The csv bodies live here as named helpers
/ rather than inline in test.csv because they contain commas, which k4unit's own csv reader
/ would take as field separators.
writecsv:{[s] (hsym `$FIXTUREDIR,"/appconfig/housekeeping.csv") 0: enlist s; }

/ the valid job csv the fixture starts with: remove *.log older than 10 days, except excluded.log
writevalidcsv:{[]
  writecsv "action,path,match,exclude,age,unit,dirs\nrm,{DIHKFIXTURE}/logs/,*.log,excluded.log,10,d,0";
  }

/ a csv naming an action that does not exist - the run must log and skip it, not throw
writeunknownactioncsv:{[]
  writecsv "action,path,match,exclude,age,unit,dirs\nnosuchaction,{DIHKFIXTURE}/logs/,*.log,,10,d,0";
  }

/ a csv with entirely the wrong columns - the run must log and abandon, not throw
writemalformedcsv:{[] writecsv "wrong,header,entirely\na,b,c"; }

/ gzip *.log older than 10 days
writegzipcsv:{[]
  writecsv "action,path,match,exclude,age,unit,dirs\ngzip,{DIHKFIXTURE}/gz/,*.log,,10,d,0";
  }

/ tar directories (dirs=1) named old* older than 10 days - the only action that takes a
/ directory, and the most destructive one here, since tar --remove-files deletes the original
writetarcsv:{[]
  writecsv "action,path,match,exclude,age,unit,dirs\ntar,{DIHKFIXTURE}/arch/,old*,,10,d,1";
  }

/ rm *.log older than 2 MINUTES - exercises the -mmin branch of findmatches, which is otherwise
/ one character away from the -mtime branch and would ship broken without a test
writeminutescsv:{[]
  writecsv "action,path,match,exclude,age,unit,dirs\nrm,{DIHKFIXTURE}/mins/,*.log,,2,m,0";
  }

/ a csv naming a custom action an app registered via addaction, rather than a built-in
writecustomactioncsv:{[]
  writecsv "action,path,match,exclude,age,unit,dirs\nnoted,{DIHKFIXTURE}/custom/,*.dat,,10,d,0";
  }

/ records what a registered custom action was handed, so a test can prove dispatch reached it
noted:`symbol$()

resetnoted:{[] `noted set `symbol$(); }

/ the handler an app would register - appends each matched path instead of deleting anything
notinghandler:{[f] `noted set noted,`$f; }

/ a custom handler that throws, as an app's own might
throwinghandler:{[f] '"deliberate failure"}

/ a throwing job followed by a working one: if the throw escapes applyjob the second job never
/ runs, and di.timer's disableonfail would take the whole schedule down with it
writethrowingcsv:{[]
  writecsv "action,path,match,exclude,age,unit,dirs\nthrows,{DIHKFIXTURE}/custom/,*.dat,,10,d,0\nnoted,{DIHKFIXTURE}/custom/,*.dat,,10,d,0";
  }

/ delete the job csv entirely - the run must log and abandon, not throw
deletecsv:{[] system "rm -f ",FIXTUREDIR,"/appconfig/housekeeping.csv"; }

/ the files still present under each of the fixture's action directories
survivors:{[] asc key hsym `$FIXTUREDIR,"/logs"}
gzfiles:{[] asc key hsym `$FIXTUREDIR,"/gz"}
archfiles:{[] asc key hsym `$FIXTUREDIR,"/arch"}
minfiles:{[] asc key hsym `$FIXTUREDIR,"/mins"}

teardownfixture:{[] system "rm -rf ",FIXTUREDIR; }

/ the startattime the module should hand di.timer for a given time of day: the next occurrence
/ on di.timer's own clock, which is UTC (cp:{.z.p}) - NOT local. Deriving it from .z.P/.z.D
/ instead makes every scheduled run late by the UTC offset, which is invisible on a
/ UTC-configured box but an hour off in e.g. BST. Mirrors the module's nextfire deliberately:
/ the point of the assertion is to pin the choice of clock, not to re-derive the arithmetic.
expectedfire:{[t] $[.z.p<ts:.z.d+t;ts;(.z.d+1)+t]}

/ the shipped framework defaults, read from the settings file itself - now that the settings tier
/ is the ONLY place a default lives, that file is what a test has to assert against. Reads it the
/ same way di.torq.config's cascade does (a flat name:value .q file).
shippeddefaults:{[] (use`di.torq.config)[`parsefile] "di/torq/settings/housekeeping.q"}

/ config-dict builders - factored out so test.csv rows never need a raw "," inline, which the
/ csv reader would take as a field separator unless the whole field were quoted and escaped.
/ every setting is required now, so each builder supplies the full set except the one it omits
/ deliberately to prove init rejects it.
basecfg:{[] `jobcsv`runtimes`runnow!(`$":",FIXTUREDIR,"/appconfig/housekeeping.csv";02:00:00;0b)}

/ jobcsv present but no runnow - init must error rather than guess, since the default now lives
/ only in the settings file
norunnowcfg:{[] `jobcsv`runtimes!(`$":",FIXTUREDIR,"/appconfig/housekeeping.csv";02:00:00)}

/ jobcsv present but no runtimes - same
noruntimescfg:{[] `jobcsv`runnow!(`$":",FIXTUREDIR,"/appconfig/housekeeping.csv";0b)}

/ jobcsv plus runnow, so init itself performs a run - the shape the process really starts in
runnowcfg:{[] `jobcsv`runtimes`runnow!(`$":",FIXTUREDIR,"/appconfig/housekeeping.csv";02:00:00;1b)}

/ several runtimes as a space-separated string, simulating a .toml-sourced setting (di.util.toml
/ has no time type, so runtimes arrive as text there but as real times from a .q settings file)
multiruntimecfg:{[] `jobcsv`runtimes`runnow!(`$":",FIXTUREDIR,"/appconfig/housekeeping.csv";"02:00 14:30";0b)}

/ runtimes as a genuine time list, the shape a .q settings file yields
timelistcfg:{[] `jobcsv`runtimes`runnow!(`$":",FIXTUREDIR,"/appconfig/housekeeping.csv";02:00:00 14:30:00;0b)}

/ no jobcsv at all - init must error rather than start a process with nothing to do
nojobcsvcfg:{[] (enlist`runtimes)!enlist 02:00:00}
