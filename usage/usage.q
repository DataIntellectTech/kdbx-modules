/ library for logging external usage of a kdb+ session
/ note that initialising this library will overwrite .z message
/ handlers with usage-logging wrappers of their current definitions

/ table to store usage info
usage:([]
  time:`timestamp$();
  id:`long$();
  extime:`timespan$();
  zcmd:`symbol$();
  status:`char$();
  a:`int$();
  u:`symbol$();
  w:`int$();
  cmd:();
  mem:();
  sz:`long$();
  error:());

/ function to generate the log file timestamp suffix
logtimestamp:{[local] $[local;.z.D;.z.d]};

/ ID for tracking external queries
id:0;

/ increment ID and return new value
nextid:{[] :.z.m.id+:1;};

/ return local time or UTC
currenttime:{[local] $[local;.z.P;.z.p]};

/ handle to the log file
logh:0;

/ write a query log message
write:{[x]
  if[.z.m.logtodisk; @[neg .z.m.logh;"|" sv .Q.s1 each x;()]];
  if[.z.m.logtomemory; .z.M.usage upsert x];
  .z.m.ext[x];
  };

// Extension function to extend the logging e.g. publish the log message
ext:{[x]};

// Exportable user accessible function to modify the value of the extension function
setextension:{[fn].z.m.ext: fn};

// Exportable user accessible function to clear any functionality assined to the extension function
clearextension:{.z.m.ext:{[x]}};

// Flush out in-memory usage records older than flushtime
flushusage:{[flushtime] delete from .z.M.usage where time<.z.m.currenttime[.z.m.localtime]-flushtime;}

// Create usage log on disk
createlog:{[logdir;logname;timestamp]
  basename:"usage_",logname,"_",string[timestamp],".log";
  / close the current log handle if there is one
  @[hclose;.z.m.logh;()];
  / open the file
  .z.m.logh:hopen hsym`$logdir,"/",basename;
  };

/ parse a usage log file and return as a usage table
readlog:{[filename]
  / remove leading backtick from symbol columns, drop "i" suffix from a and w columns and cast back to integers
  :update
    zcmd:`$1_'string zcmd,u:`$1_'string u,a:"I"$-1_'a,w:"I"$-1_'w
    from
    @[{update "J"$'" " vs' mem from flip (cols .z.m.usage)!("PJNSC*S***J*";"|")0: x};
      hsym`$filename;
      {'"failed to read log file : ",x}];
  };

/ get the memory info - we don't want to log the physical memory each time
meminfo:{[] :5#system"w";};

/ format the message handler argument as a string
formatarg:{[zcmd;arg]
  str:$[10=abs type arg;arg,();.Q.s1 arg];
  / replace %xx hexsequences in HTTP request arguments
  if[zcmd in`ph`pp;str:.h.uh str];
  :str;
  };

/ log the completion of an external request and return the result
logdirect:{[id;zcmd;endtime;result;arg;starttime]
  if[.z.m.level>1;
    .z.m.write (starttime;id;endtime-starttime;zcmd;"c";.z.a;.z.u;.z.w;.z.m.formatarg[zcmd;arg];.z.m.meminfo[];0Nj;"")];
  :result;
  };

/ log stats of query before execution
logbefore:{[id;zcmd;arg;starttime]
  if[.z.m.level>2;
    .z.m.write (starttime;id;0Nn;zcmd;"b";.z.a;.z.u;.z.w;.z.m.formatarg[zcmd;arg];.z.m.meminfo[];0Nj;"")];
  };

/ log stats of a completed query and return the result
logafter:{[id;zcmd;endtime;result;arg;starttime]
  if[.z.m.level>1;
    .z.m.write (endtime;id;endtime-starttime;zcmd;"c";.z.a;.z.u;.z.w;.z.m.formatarg[zcmd;arg];.z.m.meminfo[];-22!result;"")];
  :result;
  };

/ log stats of a failed query and raise the error
logerror:{[id;zcmd;endtime;arg;starttime;error]
  if[.z.m.level>0;
    .z.m.write (endtime;id;endtime-starttime;zcmd;"e";.z.a;.z.u;.z.w;.z.m.formatarg[zcmd;arg];.z.m.meminfo[];0Nj;error)];
  'error;
  };

/ log successful user validation
logauth:{[zcmd;handler;user;pass]
  :.z.m.logdirect[.z.m.nextid[];zcmd;.z.m.currenttime[.z.m.localtime];handler[user;pass];(user;"***");.z.m.currenttime[.z.m.localtime]];
  };

/ log successful connection opening/closing
logconnection:{[zcmd;handler;arg]
  :.z.m.logdirect[.z.m.nextid[];zcmd;.z.m.currenttime[.z.m.localtime];handler arg;arg;.z.m.currenttime[.z.m.localtime]];
  };

/ log before and after query execution is attempted
logquery:{[zcmd;handler;arg]
  id:.z.m.nextid[];
  .z.m.logbefore[id;zcmd;arg;.z.m.currenttime[.z.m.localtime]];
  :.z.m.logafter[id;zcmd;.z.m.currenttime[.z.m.localtime];@[handler;arg;.z.m.logerror[id;zcmd;.z.m.currenttime[.z.m.localtime];arg;start;]];arg;start:.z.m.currenttime[.z.m.localtime]];
  };

/ log before and after query execution is attempted, filtering with .usage.ignoreList
logqueryfiltered:{[zcmd;handler;arg]
  if[.z.m.ignore;
    if[0h=type arg;
      if[any first[arg]~/:.z.m.ignorelist;:handler arg]];
    if[10h=type arg;
      if[any arg~/:.z.m.ignorelist;:handler arg]]];
  :.z.m.logquery[zcmd;handler;arg];
  };

/ initialise .z functions with usage logging functionality
inithandlers:{[]
  / initialise unassigned message handlers with default values
  .z.pw:@[value;`.z.pw;{{[x;y] 1b}}];
  .z.po:@[value;`.z.po;{{}}];
  .z.pc:@[value;`.z.pc;{{}}];
  .z.wo:@[value;`.z.wo;{{}}];
  .z.wc:@[value;`.z.wc;{{}}];
  .z.ws:@[value;`.z.ws;{{neg[.z.w] x;}}];
  .z.pg:@[value;`.z.pg;{value}];
  .z.ps:@[value;`.z.ps;{value}];
  .z.pp:@[value;`.z.pp;{{}}];
  .z.exit:@[value;`.z.exit;{{}}];

  / reassign message handlers with usage-logging wrappers
  .z.pw:.z.m.logauth[`pw;.z.pw;;];
  .z.po:.z.m.logconnection[`po;.z.po;];
  .z.pc:.z.m.logconnection[`pc;.z.pc;];
  .z.wo:.z.m.logconnection[`wo;.z.wo;];
  .z.wc:.z.m.logconnection[`wc;.z.wc;];
  .z.ws:.z.m.logquery[`ws;.z.ws;];
  .z.pg:.z.m.logquery[`pg;.z.pg;];
  .z.ps:.z.m.logqueryfiltered[`ps;.z.ps;];
  .z.ph:.z.m.logquery[`ph;.z.ph;];
  .z.pp:.z.m.logquery[`pp;.z.pp;];
  .z.exit:.z.m.logquery[`exit;.z.exit;];
  };

/ initialise on disk usage logging, if enabled
initlog:{[]
  if[.z.m.logtodisk;
    if[""in(.z.m.logname;.z.m.logdir);
      .z.m.logtodisk:0b;
      '"logname and logdir must be set to enable on disk usage logging. logToDisk disabled"];
    .[.z.m.createlog;
      (.z.m.logdir;.z.m.logname;.z.m.logtimestamp[.z.m.localtime]);
      {.z.m.logtodisk:0b;'"Error creating log file: ",.z.m.logdir,"/usage_",.z.m.logname,"_",string[.z.m.logtimestamp[.z.m.localtime]]," | Error: " ,x}]];
  };

/ exportable function to get usage table
getusage:{[] :.z.m.usage };

init:{[configs]
  / default configuration values and flags
  .z.m.logtodisk:0b;    / whether to log to disk
  .z.m.logtomemory:1b;  / whether to log to memory
  .z.m.logdir:"";       / should be set before loading library to initialise on disk logging
  .z.m.logname:"";      / log file will take the form "usage_{logname}_{date/time}.log"
  .z.m.ignore:1b;       / whether to check the ignore list for function calls to not log
  .z.m.ignorelist:();   / list of function to not log usage of
  .z.m.level:3;         / log level,	0 = nothing, 1 = errors only, 2 = + open, close, queries, 3 = + log queries before execution
  .z.m.localtime:1b;    / check time preference. Default local time

  / set custom config values and flags
  if[not configs~(::);
    vars:`logtodisk`logtomemory`logdir`logname`ignore`ignorelist`level`localtime inter key configs;
    (.Q.dd[.z.M] each key[vars#configs]) set' value[vars#configs];
  ];

  .z.m.inithandlers[];
  .z.m.initlog[];
  };
