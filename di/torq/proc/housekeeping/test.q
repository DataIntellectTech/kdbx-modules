/ mock dependencies and fixture helpers, loaded from the repo root; calls setenv so run in its own q session

calls:([]lvl:`symbol$();ctx:`symbol$();msg:())

resetcalls:{[] `calls set ([]lvl:`symbol$();ctx:`symbol$();msg:()); }

mocklogfn:{[lvl;ctx;msg] `calls insert (lvl;ctx;msg); }

/ mock timer: records addjob calls without scheduling
scheduled:([]id:`symbol$();period:`timespan$();mode:`short$();opts:())

resetscheduled:{[] `scheduled set ([]id:`symbol$();period:`timespan$();mode:`short$();opts:()); }

mockaddjob:{[id;func;params;period;mode;opts] `scheduled insert (id;period;`short$mode;opts); }

mockdeps:{[]
  `log`timer!(
    `info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;]);
    `addjob`deletejobs`enablejobs`disablejobs`getactivejobs!(mockaddjob;{[x]};{[x]};{[x]};{[]}))
  }

/ log-only deps, for asserting init errors when the timer dep is absent
logonlydeps:{[] (enlist`log)!enlist `info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;])}

FIXTUREDIR:"/tmp/di_housekeeping_k4unit_fixture"

/ a directory of files: two to remove and three exempt (wrong extension, too recent, excluded)
setupfixture:{[]
  system "rm -rf ",FIXTUREDIR;
  system "mkdir -p ",FIXTUREDIR,"/logs";
  system "touch -d '20 days ago' ",FIXTUREDIR,"/logs/old1.log ",FIXTUREDIR,"/logs/old2.log";
  system "touch -d '20 days ago' ",FIXTUREDIR,"/logs/keep.txt ",FIXTUREDIR,"/logs/excluded.log";
  system "touch ",FIXTUREDIR,"/logs/recent.log";
  / one directory per action
  system "mkdir -p ",FIXTUREDIR,"/gz";
  system "touch -d '20 days ago' ",FIXTUREDIR,"/gz/old1.log ",FIXTUREDIR,"/gz/old2.log";
  system "mkdir -p ",FIXTUREDIR,"/arch/olddir";
  system "touch -d '20 days ago' ",FIXTUREDIR,"/arch/olddir/content.txt";
  / age the directory after filling it, since writing a file bumps its mtime
  system "touch -d '20 days ago' ",FIXTUREDIR,"/arch/olddir";
  system "mkdir -p ",FIXTUREDIR,"/mins";
  system "touch -d '5 minutes ago' ",FIXTUREDIR,"/mins/stale.log";
  system "touch ",FIXTUREDIR,"/mins/justnow.log";
  / for the addaction test
  system "mkdir -p ",FIXTUREDIR,"/custom";
  system "touch -d '20 days ago' ",FIXTUREDIR,"/custom/target.dat";
  / a 5-column csv, a null row, and rm matching a directory
  system "mkdir -p ",FIXTUREDIR,"/five ",FIXTUREDIR,"/nulls ",FIXTUREDIR,"/rmdir/olddir";
  system "touch -d '20 days ago' ",FIXTUREDIR,"/five/old.log ",FIXTUREDIR,"/nulls/old.log ",FIXTUREDIR,"/rmdir/olddir";
  system "mkdir -p ",FIXTUREDIR,"/appconfig";
  writevalidcsv[];
  setenv[`DIHKFIXTURE;FIXTUREDIR];
  }

/ write the job csv the fixture config points at
writecsv:{[s] (hsym `$FIXTUREDIR,"/appconfig/housekeeping.csv") 0: enlist s; }

/ the valid job csv the fixture starts with: remove *.log older than 10 days, except excluded.log
writevalidcsv:{[]
  writecsv "function,path,match,exclude,age,agemin,checkfordirectory\nrm,{DIHKFIXTURE}/logs/,*.log,excluded.log,10,0,0";
  }

/ a csv naming an action that does not exist - the run must log and skip it, not throw
writeunknownactioncsv:{[]
  writecsv "function,path,match,exclude,age,agemin,checkfordirectory\nnosuchaction,{DIHKFIXTURE}/logs/,*.log,,10,0,0";
  }

/ a csv with entirely the wrong columns - the run must log and abandon, not throw
writemalformedcsv:{[] writecsv "wrong,header,entirely\na,b,c"; }

/ zip *.log older than 10 days
writegzipcsv:{[]
  writecsv "function,path,match,exclude,age,agemin,checkfordirectory\nzip,{DIHKFIXTURE}/gz/,*.log,,10,0,0";
  }

/ tardir directories (checkfordirectory=1) named old* older than 10 days
writetarcsv:{[]
  writecsv "function,path,match,exclude,age,agemin,checkfordirectory\ntardir,{DIHKFIXTURE}/arch/,old*,,10,0,1";
  }

/ rm *.log older than 2 minutes (-mmin)
writeminutescsv:{[]
  writecsv "function,path,match,exclude,age,agemin,checkfordirectory\nrm,{DIHKFIXTURE}/mins/,*.log,,2,1,0";
  }

/ a csv naming a custom action an app registered via addaction, rather than a built-in
writecustomactioncsv:{[]
  writecsv "function,path,match,exclude,age,agemin,checkfordirectory\nnoted,{DIHKFIXTURE}/custom/,*.dat,,10,0,0";
  }

/ records what a registered custom action was handed
noted:`symbol$()

resetnoted:{[] `noted set `symbol$(); }

/ a custom handler that appends each matched path instead of deleting
notinghandler:{[f] `noted set noted,`$f; }

/ a custom handler that throws, as an app's own might
throwinghandler:{[f] '"deliberate failure"}

/ a throwing job followed by a working one
writethrowingcsv:{[]
  writecsv "function,path,match,exclude,age,agemin,checkfordirectory\nthrows,{DIHKFIXTURE}/custom/,*.dat,,10,0,0\nnoted,{DIHKFIXTURE}/custom/,*.dat,,10,0,0";
  }

/ a 5-column csv: agemin and checkfordirectory default to 0b
writefivecsv:{[] writecsv "function,path,match,exclude,age\nrm,{DIHKFIXTURE}/five/,*.log,,10"; }

/ a row with a null age is skipped and the next row still runs
writenullcsv:{[] writecsv "function,path,match,exclude,age,agemin,checkfordirectory\nrm,{DIHKFIXTURE}/nulls/,*.log,,,,\nrm,{DIHKFIXTURE}/nulls/,*.log,,10,,"; }

/ rm matching a directory: skipped and logged
writermdircsv:{[] writecsv "function,path,match,exclude,age,agemin,checkfordirectory\nrm,{DIHKFIXTURE}/rmdir/,old*,,10,0,1"; }

/ delete the job csv entirely - the run must log and abandon, not throw
deletecsv:{[] system "rm -f ",FIXTUREDIR,"/appconfig/housekeeping.csv"; }

/ the files still present under each of the fixture's action directories
survivors:{[] asc key hsym `$FIXTUREDIR,"/logs"}
gzfiles:{[] asc key hsym `$FIXTUREDIR,"/gz"}
archfiles:{[] asc key hsym `$FIXTUREDIR,"/arch"}
minfiles:{[] asc key hsym `$FIXTUREDIR,"/mins"}
dirfiles:{[d] asc key hsym `$FIXTUREDIR,"/",d}

teardownfixture:{[] system "rm -rf ",FIXTUREDIR; }

/ the startattime expected for a time of day, on di.timer's UTC clock
expectedfire:{[t] $[.z.p<ts:.z.d+t;ts;(.z.d+1)+t]}

/ the defaults in di/torq/settings/housekeeping.q, parsed as di.torq.config does
shippeddefaults:{[] (use`di.torq.config)[`parsefile] "di/torq/settings/housekeeping.q"}

/ config-dict builders
basecfg:{[] `jobcsv`runtimes`runnow!(`$":",FIXTUREDIR,"/appconfig/housekeeping.csv";02:00:00;0b)}

/ jobcsv present but no runnow
norunnowcfg:{[] `jobcsv`runtimes!(`$":",FIXTUREDIR,"/appconfig/housekeeping.csv";02:00:00)}

/ jobcsv present but no runtimes
noruntimescfg:{[] `jobcsv`runnow!(`$":",FIXTUREDIR,"/appconfig/housekeeping.csv";0b)}

/ jobcsv plus runnow, so init itself performs a run
runnowcfg:{[] `jobcsv`runtimes`runnow!(`$":",FIXTUREDIR,"/appconfig/housekeeping.csv";02:00:00;1b)}

/ several runtimes as a space-separated string, as from .toml settings
multiruntimecfg:{[] `jobcsv`runtimes`runnow!(`$":",FIXTUREDIR,"/appconfig/housekeeping.csv";"02:00 14:30";0b)}

/ runtimes as a time list, as from .q settings
timelistcfg:{[] `jobcsv`runtimes`runnow!(`$":",FIXTUREDIR,"/appconfig/housekeeping.csv";02:00:00 14:30:00;0b)}

/ no jobcsv
nojobcsvcfg:{[] (enlist`runtimes)!enlist 02:00:00}
