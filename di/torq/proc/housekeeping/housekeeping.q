/ di.torq.proc.housekeeping - scheduled file-maintenance process type. Applies a list of
/ cleanup jobs (remove / gzip / tar files or directories older than some age) read from a csv,
/ on a daily schedule. Ported from TorQ/code/processes/housekeeping.q.
/ ---
/ Scope (v1): unix only. Legacy shipped parallel .unix.*/.win.* implementations and dispatched
/ on .z.o; the .win branch is NOT ported (its own zip/tar were never implemented there, and the
/ framework tier has dropped Windows elsewhere - see di.torq.logroll's same note). init errors
/ on Windows rather than starting half-working. Also NOT ported: legacy's kdbzip action (kdb
/ -19! column compression) - that whole concern belongs to di.compression, which does it far
/ more thoroughly; and legacy's "runnow then exit" one-shot mode (see runnow below).
/ ---
/ Why a csv for the jobs and settings for the rest: the job list is tabular and
/ variable-length (one row per path/match/action), which a .q/.toml settings file models
/ badly - same split di.torq.proc.wdb uses for its sortcsv and di.compression for its own csv.
/ Settings hold only WHEN to run and WHERE the csv is.

/ has init run? probes .z.m.log, which has no load-time default - only init ever sets it - via a
/ trap rather than a `in key .z.m` test, so it cannot be confused by how module state is shaped.
/ Same shape as di.merge's own init guard.
initialised:{[] @[{.z.m.log;1b};::;{[e] 0b}]}

/ an exported function that touches injected deps or config refuses to run before init wired them.
/ Without this a pre-init call dies on an unset .z.m.log (or .z.m.jobcsv) with a raw error that
/ says nothing about the real mistake. actionnames is deliberately NOT guarded - it only reads the
/ action dictionary, which exists from load, so it answers correctly whether or not init has run.
requireinit:{[ctx]
  if[not initialised[];
    '"di.torq.proc.housekeeping: ",string[ctx],": init must be called before any other function"];
  }

/ a time-of-day list config (runtimes): accept a minute/second/time/timespan atom or list (from
/ a .q settings file), or a space-separated string ("02:00 14:30") from .toml - always returns a
/ timespan list, which adds to a date to give the next fire timestamp.
/ NB the two branches use different casts on purpose: "N"$ PARSES text and cannot cast a real
/ temporal value, while `timespan$ CASTS any temporal type (including timespan) but cannot parse
/ text. Using either alone throws 'type on the other branch's input - caught by direct testing.
astimespans:{[x]
  $[10h=type x;"N"$" " vs x;
    0>type x;enlist `timespan$x;
    `timespan$x]
  }

/ base dir: the job csv is CODE/CONFIG, not runtime data, so it resolves under TORQXAPPHOME -
/ matching how di.torq.proc.wdb resolves its own sortcsv (and unlike its savedir/hdbdir, which
/ are data and resolve under TORQXDATAHOME).
apphome:{getenv[`TORQXAPPHOME]}

/ resolve a possibly-relative path setting to an absolute path STRING (no leading `:`) under
/ `base`. Same body as di.torq.proc.wdb's resolvedir - accepts a `.q` settings symbol (`:x) or
/ a colon-less `.toml` string ("x") and normalises both.
resolvepath:{[base;path]
  path:$[10h=abs type path;path;string path];
  path:$[(0<count path) and ":"=first path;1_path;path];
  $[path like "/*";path;base,"/",path]
  }

/ the next timestamp at which time-of-day `t` occurs: today if it hasn't passed yet, otherwise
/ tomorrow - so a process started after its configured time waits for the next one rather than
/ firing immediately on startup (use runnow for that). Mirrors legacy TorQ's own scheduling.
/ ---
/ UTC (.z.p/.z.d), NOT local (.z.P/.z.D), because di.timer's own clock is `cp:{.z.p}` and it
/ fires a job when cp[] reaches the nextstart we hand it. Computing this in local time makes
/ every run late by the UTC offset - on a UTC+1 box a "02:00" job silently fires at 03:00 local.
/ Caught by running a real process and reading the live job table, not by the tests: the mocked
/ timer records what it was handed but never fires it, and on a UTC box the two agree anyway.
/ So `runtimes` are UTC times of day - see housekeeping.md.
nextfire:{[t]
  $[.z.p<ts:.z.d+t;ts;(.z.d+1)+t]
  }

/ expand {ENVVAR} placeholders in a job's path, so a csv can follow a deployment's environment
/ instead of hardcoding absolute paths (e.g. "{TORQXLOGDIR}/"). Legacy TorQ did the same via
/ .rmvr.removeenvvar. An unset variable expands to empty, matching shell behaviour; an unmatched
/ "{" is left alone rather than treated as an error.
expandenv:{[s]
  c:"{" vs s;
  first[c],raze {i:x?"}";$[i=count x;"{",x;getenv[`$i#x],(i+1)_x]} each 1_c
  }

/ the job csv's schema: column name -> its 0: type char, in order. Deliberately ONE structure
/ rather than a name list beside a "S***ISB" literal - they have to agree positionally, and
/ nothing but care keeps two parallel lists in step when a column is added.
/ NOT a setting, despite looking like config: these names are compiled into the field accesses
/ in findmatches/applyjob (j`action, j`path, ...), so an operator who renamed one would get a
/ csv that passes the header check and then fails on first use. Renamed from legacy TorQ's
/ function/agemin/checkfordirectory for clarity; housekeeping.md has the migration mapping.
jobschema:`action`path`match`exclude`age`unit`dirs!"S***ISB"

/ read the job list. Re-read on every run rather than cached at init, so an operator can edit
/ the csv without bouncing the process (legacy read it per run too). All columns are required -
/ legacy allowed trailing optional ones and needed a fragile rename dance to cope; a strict
/ header with a clear error is easier to get right than to debug.
readjobs:{[path]
  f:hsym `$path;
  if[not count key f;'"job csv not found at ",path];
  t:(value jobschema;enlist ",") 0: f;
  if[not (key jobschema)~cols t;
    '"job csv ",path," has columns ",(", " sv string cols t),"; expected ",", " sv string key jobschema];
  t
  }

/ locate the paths one job matches. Shells out to find because kdb has no native stat, so file
/ age can only come from the OS - legacy TorQ shelled out for the same reason. -maxdepth 1 keeps
/ a job to the directory it names rather than recursing into a whole tree by accident.
/ NB the csv is operator-supplied config, at the same trust level as a settings file, so its
/ values reach the shell - they are quoted, but a csv is not a place to accept untrusted input.
findmatches:{[j]
  p:expandenv j`path;
  flag:$[j`dirs;"d";"f"];
  agearg:$[`m=j`unit;"-mmin";"-mtime"];
  cmd:"find \"",p,"\" -maxdepth 1 -type ",flag," -name \"",(j`match),"\" ",agearg," +",string j`age;
  if[count j`exclude;cmd,:" ! -name \"",(j`exclude),"\""];
  @[system;cmd;{[e] .z.m.log[`error][`findmatches;"find failed: ",e];()}]
  }

/ one handler per action, dispatched by the csv's `action` column. rm goes through di.os so it
/ picks the right call for a file vs a directory (and honours di.os's dry-run mode); gzip/tar
/ have no di.os equivalent and shell out directly - part of why this module is unix-only.
actions:()!()

actions[`rm]:{[f]
  .z.m.log[`info][`rm;"removing ",f];
  @[$[(.z.m.os`isdir)f;.z.m.os`deldir;.z.m.os`del];f;{[f;e] .z.m.log[`error][`rm;"failed to remove ",f,": ",e]}[f]];
  }

actions[`gzip]:{[f]
  .z.m.log[`info][`gzip;"compressing ",f];
  @[system;"gzip \"",f,"\"";{[f;e] .z.m.log[`error][`gzip;"failed to compress ",f,": ",e]}[f]];
  }

actions[`tar]:{[f]
  .z.m.log[`info][`tar;"archiving ",f];
  @[system;"tar -czf \"",f,".tar.gz\" \"",f,"\" --remove-files";{[f;e] .z.m.log[`error][`tar;"failed to archive ",f,": ",e]}[f]];
  }

/ the actions a job csv may name, for error messages and for an app to introspect
actionnames:{[] key actions}

/ register an extra action an app's own job csv rows can dispatch to, e.g.
/   hk:use`di.torq.proc.housekeeping;
/   (hk`addaction)[`s3upload;{[f] ... }];
/ from a file under $TORQXAPPHOME/code/, which di.torq loads after this module's init.
/ ---
/ This is the front door for what legacy TorQ got by having `wrapper` `value` ANY root-level
/ function the csv named ("designed to be extended through user defined functions"). That was
/ extensible but unbounded - a csv naming `exit`, or any root function, got it called with file
/ paths. Dispatch here stays closed over this dictionary; an app adds to it deliberately.
/ ---
/ Needed because a bare `actions[`x]:...` from app code does NOT reach this dictionary: app code
/ is loaded with system "l" and lands at ROOT, while this module's `actions` lives in the private
/ namespace `use` mangles it into. The app ends up amending an unrelated root dictionary of the
/ same name, the csv row is still rejected as an unknown action, and nothing says why until a
/ scheduled run logs it. Reaching the real one means spelling the mangled path
/ (.m.di.0torq.0proc.0housekeeping.actions), which is an implementation detail, not an interface.
addaction:{[name;handler]
  requireinit[`addaction];
  if[not -11h=type name;'"di.torq.proc.housekeeping: addaction name must be a symbol"];
  if[not 100h=type handler;'"di.torq.proc.housekeeping: addaction handler must be a function taking one matched path"];
  / refuse to shadow a built-in: silently swapping rm/gzip/tar out from under a job csv that
  / already names them is a footgun no caller wants, and a typo'd name should say so loudly
  if[name in `rm`gzip`tar;
    '"di.torq.proc.housekeeping: cannot redefine the built-in action ",string name];
  if[name in key actions;
    .z.m.log[`warn][`addaction;"replacing already-registered action ",string name]];
  actions[name]:handler;
  .z.m.log[`info][`addaction;"registered action ",(string name),"; csv actions now: ",", " sv string key actions];
  }

/ apply one job: find what it matches, then run its action over each match. An unknown action or
/ a failing find is logged and skipped rather than aborting the whole run - one bad csv row
/ should not stop the rest of the night's housekeeping.
applyjob:{[j]
  if[not (j`action) in key actions;
    .z.m.log[`error][`applyjob;"unknown action ",(string j`action),"; expected one of ",", " sv string key actions];
    :()];
  m:findmatches j;
  .z.m.log[`info][`applyjob;(string j`action)," ",(j`match)," in ",(expandenv j`path),": ",(string count m)," match(es)"];
  actions[j`action] each m;
  }

/ run every job in the csv once. Called by the timer, by runnow at startup, and by an operator
/ or peer over IPC as .housekeeping.runjobs[]. A csv that is missing or malformed is logged and
/ the run abandoned - the process stays up and tries again on the next schedule.
runjobs:{[]
  requireinit[`runjobs];
  .z.m.log[`info][`runjobs;"housekeeping starting, reading ",.z.m.jobcsv];
  jobs:@[readjobs;.z.m.jobcsv;{[e] .z.m.log[`error][`runjobs;"cannot read job csv: ",e];()}];
  if[not count jobs;:()];
  applyjob each jobs;
  .z.m.log[`info][`runjobs;"housekeeping complete, ran ",(string count jobs)," job(s)"];
  }

/ register one daily timer job per configured runtime. di.timer mode 1h reschedules at
/ (previous SCHEDULED start + period), so a fixed 1-day period stays pinned to the configured
/ time of day even if a run overruns; `startattime` sets the first fire (see di.timer's
/ addjob.custom opts).
schedule:{[]
  {[i;t]
    id:`$"housekeeping",string i;
    (.z.m.timer`addjob)[id;runjobs;();86400;1h;enlist[`startattime]!enlist f:nextfire t];
    .z.m.log[`info][`schedule;"scheduled ",(string id)," first run at ",string f];
    }'[til count .z.m.runtimes;.z.m.runtimes];
  }

init:{[config;deps]
  if[not `log in key deps;'"di.torq.proc.housekeeping: log dependency is required - see di.util.log"];
  .z.m.log:deps`log;
  if[not `timer in key deps;'"di.torq.proc.housekeeping: timer dependency is required - see di.timer"];
  .z.m.timer:deps`timer;
  if[.z.o in `w32`w64;'"di.torq.proc.housekeeping: windows is not supported - the job actions need unix find/gzip/tar (see housekeeping.md)"];
  if[not `jobcsv in key config;'"di.torq.proc.housekeeping: jobcsv is required - the path to the housekeeping job list (see housekeeping.md)"];
  .z.m.jobcsv:resolvepath[apphome[];config`jobcsv];
  / presence-check-with-default, per consistency.md's stated convention for a process module's
  / tunables. `config` is ALREADY the merged cascade (framework settings -> app settings -> command
  / line), so there is no separate settings lookup to do here - the default below only applies to a
  / caller that bypasses the cascade entirely and calls init directly, e.g. the tests.
  / These defaults must agree with di/torq/settings/housekeeping.q, which is what makes them
  / discoverable and command-line-overridable (an undeclared setting is skipped by the override
  / tier). Tests assert both halves, because a silently disagreeing pair is how legacy TorQ shipped
  / runtimes:02:00:00 in settings and a dead 12:00 in code - with its -hkusage text quoting 12:00.
  .z.m.runtimes:$[`runtimes in key config;astimespans config`runtimes;enlist 0D02:00:00];
  / di.os for the rm action - it picks file vs directory, and its dry-run mode is what lets the
  / tests assert on a destructive action without destroying anything. Deliberately NOT declared
  / in a deps.toml: di.os ships no VERSION file, so declaring it would fail di.torq.depcheck's
  / manifest walk outright (see housekeeping.md). Add the declaration once di.os carries one.
  .z.m.os:use`di.os;
  / publish the IPC-callable surface at a real root-level name - use-loading this file compiles
  / it into a private namespace (see di.torq.proc.hdb.init's identical note), so a remote or
  / operator call would otherwise hit an undefined-function error.
  / NB the name is `runjobs` everywhere - here, in the export, and as the function itself - and
  / deliberately never `run`: di.torq's runhook fires `.{proctype}.run[]` once after init for any
  / process type that publishes one, so publishing `run` would silently perform a destructive
  / cleanup pass on EVERY process start, reversing legacy TorQ's runnow:0b default and making the
  / runnow setting below dead. Caught by running the process for real; the mocked unit tests
  / can't see it, since the hook lives in di.torq, not in this module.
  set[`.housekeeping.runjobs;runjobs];
  schedule[];
  / runnow means "also run once now", NOT legacy's "run once and exit" - exiting from inside
  / init would fight torqx.sh, which owns this process's lifecycle. A one-shot cleanup is a cron
  / job calling .housekeeping.runjobs[] over IPC, not a process that kills itself.
  if[$[`runnow in key config;`boolean$config`runnow;0b];runjobs[]];
  .z.m.log[`info][`init;"initialised, jobcsv=",.z.m.jobcsv,", runtimes=",", " sv string .z.m.runtimes];
  }
