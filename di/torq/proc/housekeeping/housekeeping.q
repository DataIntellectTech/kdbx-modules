/ di.torq.proc.housekeeping - runs file-maintenance jobs (rm, zip or tardir files or directories older than an age)
/ from a job csv on a daily schedule; unix only

/ has init run? traps a read of .z.m.log, which only init sets
initialised:{[] @[{.z.m.log;1b};::;{[e] 0b}]}

/ signal if an exported function is called before init
requireinit:{[ctx]
  if[not initialised[];
    '"di.torq.proc.housekeeping: ",string[ctx],": init must be called before any other function"];
  }

/ runtimes config as a timespan list: a temporal atom or list (.q settings) or a space-separated string (.toml)
astimespans:{[x]
  $[10h=type x;"N"$" " vs x;
    0>type x;enlist `timespan$x;
    `timespan$x]
  }

/ base dir for the job csv
apphome:{getenv[`TORQXAPPHOME]}

/ resolve a possibly-relative path setting (symbol or string, optional leading colon) to an absolute path string under base
resolvepath:{[base;path]
  path:$[10h=abs type path;path;string path];
  path:$[(0<count path) and ":"=first path;1_path;path];
  $[path like "/*";path;base,"/",path]
  }

/ the next UTC timestamp at time of day t: today if not yet passed, otherwise tomorrow
nextfire:{[t]
  $[.z.p<ts:.z.d+t;ts;(.z.d+1)+t]
  }

/ expand {ENVVAR} placeholders in a job's path; an unset variable expands to empty, an unmatched { is kept
expandenv:{[s]
  c:"{" vs s;
  first[c],raze {i:x?"}";$[i=count x;"{",x;getenv[`$i#x],(i+1)_x]} each 1_c
  }

/ read the job list; re-read on every run
readjobs:{[path]
  f:hsym `$path;
  if[not count key f;'"job csv not found at ",path];
  t:("S***IBB";enlist ",") 0: f;
  / columns 6 and 7 are named by position; a 5-column csv gets them as 0b
  t:@[cols t;5 6;:;`agemin`checkfordirectory] xcol t;
  if[not all `function`path`match`exclude`age`agemin`checkfordirectory in cols t;'"job csv ",path," has incorrect layout"];
  / rows with a null function or age are skipped
  if[any n:null[t`function] or null t`age;.z.m.log[`info][`readjobs;"Null values found in file, skipping line(s)  ",", " sv string where n]];
  t where not n
  }

/ paths one job matches, from find -maxdepth 1 by age in days (-mtime) or minutes (-mmin); csv values are quoted into the shell command
findmatches:{[j]
  p:expandenv j`path;
  flag:$[j`checkfordirectory;"d";"f"];
  agearg:$[j`agemin;"-mmin";"-mtime"];
  cmd:"find \"",p,"\" -maxdepth 1 -type ",flag," -name \"",(j`match),"\" ",agearg," +",string j`age;
  if[count j`exclude;cmd,:" ! -name \"",(j`exclude),"\""];
  @[system;cmd;{[e] .z.m.log[`error][`findmatches;"find failed: ",e];()}]
  }

/ one handler per action, dispatched by the csv's function column; rm goes through di.os, zip and tardir shell out
actions:()!()

actions[`rm]:{[f]
  / a directory is not removed
  if[(.z.m.os`isdir)f;'"cannot remove ",f,": Is a directory"];
  .z.m.log[`info][`rm;"removing ",f];
  (.z.m.os`del) f;
  }

actions[`zip]:{[f]
  .z.m.log[`info][`zip;"compressing ",f];
  system "gzip \"",f,"\"";
  }

actions[`tardir]:{[f]
  .z.m.log[`info][`tardir;"archiving ",f];
  system "tar -czf \"",f,".tar.gz\" \"",f,"\" --remove-files";
  }

/ the actions a job csv may name, for error messages and for an app to introspect
actionnames:{[] key actions}

/ register an extra action an app's job csv rows can dispatch to, e.g.
/   hk:use`di.torq.proc.housekeeping;
/   (hk`addaction)[`s3upload;{[f] ... }];
addaction:{[name;handler]
  requireinit[`addaction];
  if[not -11h=type name;'"di.torq.proc.housekeeping: addaction name must be a symbol"];
  if[not 100h=type handler;'"di.torq.proc.housekeeping: addaction handler must be a function taking one matched path"];
  / built-in actions cannot be replaced
  if[name in `rm`zip`tardir;
    '"di.torq.proc.housekeeping: cannot redefine the built-in action ",string name];
  if[name in key actions;
    .z.m.log[`warn][`addaction;"replacing already-registered action ",string name]];
  actions[name]:handler;
  .z.m.log[`info][`addaction;"registered action ",(string name),"; csv actions now: ",", " sv string key actions];
  }

/ apply one job: find its matches and run its action on each; an unknown action, a failing find or a throwing
/ action is logged and skipped
applyjob:{[j]
  if[not (j`function) in key actions;
    .z.m.log[`error][`applyjob;"unknown action ",(string j`function),"; expected one of ",", " sv string key actions];
    :()];
  m:findmatches j;
  .z.m.log[`info][`applyjob;(string j`function)," ",(j`match)," in ",(expandenv j`path),": ",(string count m)," match(es)"];
  {[a;f] @[actions a;f;{[a;f;e] .z.m.log[`error][`applyjob;"action ",(string a)," failed on ",f,": ",e]}[a;f]]}[j`function;] each m;
  }

/ run every job in the csv once, published at root as .housekeeping.runjobs; a missing or malformed csv is
/ logged and the run abandoned; a failing job is logged and the rest still run
runjobs:{[]
  requireinit[`runjobs];
  .z.m.log[`info][`runjobs;"housekeeping starting, reading ",.z.m.jobcsv];
  jobs:@[readjobs;.z.m.jobcsv;{[e] .z.m.log[`error][`runjobs;"cannot read job csv: ",e];()}];
  if[not count jobs;:()];
  {[j] @[applyjob;j;{[j;e] .z.m.log[`error][`runjobs;"job ",(string j`function)," failed: ",e]}[j]]} each jobs;
  .z.m.log[`info][`runjobs;"housekeeping complete, ran ",(string count jobs)," job(s)"];
  }

/ register one daily di.timer job per runtime, mode 1h, first fire at nextfire
schedule:{[]
  {[i;t]
    id:`$"housekeeping",string i;
    (.z.m.timer`addjob)[id;runjobs;();1D;1h;`startattime`dupcheck!(f:nextfire t;0b)];
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
  / defaults match di/torq/settings/housekeeping.q
  .z.m.runtimes:$[`runtimes in key config;astimespans config`runtimes;enlist 0D02:00:00];
  / di.os for the rm action
  .z.m.os:use`di.os;
  / publish runjobs at root for IPC callers
  set[`.housekeeping.runjobs;runjobs];
  schedule[];
  / runnow runs the jobs once at init
  if[$[`runnow in key config;`boolean$config`runnow;0b];runjobs[]];
  .z.m.log[`info][`init;"initialised, jobcsv=",.z.m.jobcsv,", runtimes=",", " sv string .z.m.runtimes];
  }
