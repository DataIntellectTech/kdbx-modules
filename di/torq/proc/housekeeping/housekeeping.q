/ true once init has set the log dependency
initialised:{[] @[{.z.m.log;1b};::;{[e] 0b}]}

/ signals if init has not been called
requireinit:{[ctx]
  if[not initialised[];
    '"di.torq.proc.housekeeping: ",string[ctx],": init must be called before any other function"];
  }

/ runtimes setting to a timespan list: "N"$ parses text, `timespan$ casts temporals
astimespans:{[x]
  $[10h=type x;"N"$" " vs x;
    0>type x;enlist `timespan$x;
    `timespan$x]
  }

/ the app root that relative paths resolve against
apphome:{getenv[`TORQXAPPHOME]}

/ resolves a possibly-relative path setting to an absolute path string
resolvepath:{[base;path]
  path:$[10h=abs type path;path;string path];
  path:$[(0<count path) and ":"=first path;1_path;path];
  $[path like "/*";path;base,"/",path]
  }

/ next occurrence of time-of-day t, in UTC because di.timer fires on .z.p
nextfire:{[t]
  $[.z.p<ts:.z.d+t;ts;(.z.d+1)+t]
  }

/ substitutes {VAR} in a job path with its environment value
expandenv:{[s]
  c:"{" vs s;
  first[c],raze {i:x?"}";$[i=count x;"{",x;getenv[`$i#x],(i+1)_x]} each 1_c
  }

/ job csv columns and their types
jobschema:`action`path`match`exclude`age`unit`dirs!"S***ISB"

/ loads and validates the job csv
readjobs:{[path]
  f:hsym `$path;
  if[not count key f;'"job csv not found at ",path];
  t:(value jobschema;enlist ",") 0: f;
  if[not (key jobschema)~cols t;
    '"job csv ",path," has columns ",(", " sv string cols t),"; expected ",", " sv string key jobschema];
  t
  }

/ paths matching one job's pattern and age, via find
findmatches:{[j]
  p:expandenv j`path;
  flag:$[j`dirs;"d";"f"];
  agearg:$[`m=j`unit;"-mmin";"-mtime"];
  cmd:"find \"",p,"\" -maxdepth 1 -type ",flag," -name \"",(j`match),"\" ",agearg," +",string j`age;
  if[count j`exclude;cmd,:" ! -name \"",(j`exclude),"\""];
  @[system;cmd;{[e] .z.m.log[`error][`findmatches;"find failed: ",e];()}]
  }

/ action name -> handler taking one matched path
actions:()!()

actions[`rm]:{[f]
  .z.m.log[`info][`rm;"removing ",f];
  ($[(.z.m.os`isdir)f;.z.m.os`deldir;.z.m.os`del]) f;
  }

actions[`gzip]:{[f]
  .z.m.log[`info][`gzip;"compressing ",f];
  system "gzip \"",f,"\"";
  }

actions[`tar]:{[f]
  .z.m.log[`info][`tar;"archiving ",f];
  system "tar -czf \"",f,".tar.gz\" \"",f,"\" --remove-files";
  }

/ names of the registered actions
actionnames:{[] key actions}

/ registers a custom action; app code cannot reach the private `actions` directly
addaction:{[name;handler]
  requireinit[`addaction];
  if[not -11h=type name;'"di.torq.proc.housekeeping: addaction name must be a symbol"];
  if[not 100h=type handler;'"di.torq.proc.housekeeping: addaction handler must be a function taking one matched path"];
  if[name in `rm`gzip`tar;
    '"di.torq.proc.housekeeping: cannot redefine the built-in action ",string name];
  if[name in key actions;
    .z.m.log[`warn][`addaction;"replacing already-registered action ",string name]];
  actions[name]:handler;
  .z.m.log[`info][`addaction;"registered action ",(string name),"; csv actions now: ",", " sv string key actions];
  }

/ runs one job over its matches, trapping each so a throw cannot disable the di.timer job
applyjob:{[j]
  if[not (j`action) in key actions;
    .z.m.log[`error][`applyjob;"unknown action ",(string j`action),"; expected one of ",", " sv string key actions];
    :()];
  m:findmatches j;
  .z.m.log[`info][`applyjob;(string j`action)," ",(j`match)," in ",(expandenv j`path),": ",(string count m)," match(es)"];
  {[a;f] @[actions a;f;{[a;f;e] .z.m.log[`error][`applyjob;"action ",(string a)," failed on ",f,": ",e]}[a;f]]}[j`action;] each m;
  }

/ reads the job csv and runs every job
runjobs:{[]
  requireinit[`runjobs];
  .z.m.log[`info][`runjobs;"housekeeping starting, reading ",.z.m.jobcsv];
  jobs:@[readjobs;.z.m.jobcsv;{[e] .z.m.log[`error][`runjobs;"cannot read job csv: ",e];()}];
  if[not count jobs;:()];
  {[j] @[applyjob;j;{[j;e] .z.m.log[`error][`runjobs;"job ",(string j`action)," failed: ",e]}[j]]} each jobs;
  .z.m.log[`info][`runjobs;"housekeeping complete, ran ",(string count jobs)," job(s)"];
  }

/ adds a daily timer job for each runtime
schedule:{[]
  {[i;t]
    id:`$"housekeeping",string i;
    (.z.m.timer`addjob)[id;runjobs;();86400;1h;enlist[`startattime]!enlist f:nextfire t];
    .z.m.log[`info][`schedule;"scheduled ",(string id)," first run at ",string f];
    }'[til count .z.m.runtimes;.z.m.runtimes];
  }

/ reads deps and config, schedules the jobs, and optionally runs them now
init:{[config;deps]
  if[not `log in key deps;'"di.torq.proc.housekeeping: log dependency is required - see di.util.log"];
  .z.m.log:deps`log;
  if[not `timer in key deps;'"di.torq.proc.housekeeping: timer dependency is required - see di.timer"];
  .z.m.timer:deps`timer;
  if[.z.o in `w32`w64;'"di.torq.proc.housekeeping: windows is not supported - the job actions need unix find/gzip/tar (see housekeeping.md)"];
  if[not `jobcsv in key config;'"di.torq.proc.housekeeping: jobcsv is required - the path to the housekeeping job list (see housekeeping.md)"];
  .z.m.jobcsv:resolvepath[apphome[];config`jobcsv];
  .z.m.runtimes:$[`runtimes in key config;astimespans config`runtimes;enlist 0D02:00:00];
  / not in deps.toml: di.os has no VERSION, which fails depcheck
  .z.m.os:use`di.os;
  / never publish `run` - di.torq calls .{proctype}.run[] on startup
  set[`.housekeeping.runjobs;runjobs];
  schedule[];
  if[$[`runnow in key config;`boolean$config`runnow;0b];runjobs[]];
  .z.m.log[`info][`init;"initialised, jobcsv=",.z.m.jobcsv,", runtimes=",", " sv string .z.m.runtimes];
  }
