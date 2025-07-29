/ library for logging external usage of a kdb+ session
/ note that initialising this library will overwrite .z message
/ handlers with usage-logging wrappers of their current definitions

/ table to store usage info
.usage.usage:@[value;`.usage.usage;([]
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
  error:())];

/ flags and variables

/ whether to log to disk
.usage.logtodisk:@[value;`.usage.logtodisk;0b];

/ whether to log to memory
.usage.logtomemory:@[value;`.usage.logtomemory;1b];

/ whether to check the ignore list for function calls to not log
.usage.ignore:@[value;`.usage.ignore;1b];

/ list of function to not log usage of
.usage.ignorelist:@[value;`.usage.ignorelist;()];

/ function to generate the log file timestamp suffix
.usage.logtimestamp:@[value;`.usage.logtimestamp;{{[local] $[local;.z.D;.z.d]}}];

/ log directory
/ should be set before loading library to initialise on disk logging
.usage.logdir:@[value;`.usage.logdir;""];

/ log file will take the form "usage_{logname}_{date/time}.log"
/ should be set before loading library to initialise on disk logging
.usage.logname:@[value;`.usage.logname;""];

/ log level
/	0 = nothing
/	1 = errors only
/	2 = + open, close, queries
/	3 = + log queries before execution
.usage.level:@[value;`.usage.level;3];

/ ID for tracking external queries
.usage.id:@[value;`.usage.id;0];

/ increment ID and return new value
.usage.nextid:{[] :.usage.id+:1;};

/ check time preference. Default local time
.usage.localtime:@[value;`.usage.localtime;1b];

/ return local time or UTC
.usage.currenttime:{[local] $[local;.z.P;.z.p]};

/ handle to the log file
.usage.logh:@[value;`.usage.logh;0];

/ write a query log message
.usage.write:{[x]
  if[.usage.logtodisk; @[neg .usage.logh;"|" sv .Q.s1 each x;()]];
  if[.usage.logtomemory;`.usage.usage upsert x];
  .usage.ext[x];
  };

// Extension function to extend the logging e.g. publish the log message
.usage.ext:{[x]};

// Flush out in-memory usage records older than flushtime
.usage.flushusage:{[flushtime] delete from `.usage.usage where time<.usage.currenttime[.usage.localtime]-flushtime;}

// Create usage log on disk
.usage.createlog:{[logdir;logname;timestamp]
  basename:"usage_",logname,"_",string[timestamp],".log";
  / close the current log handle if there is one
  @[hclose;.usage.logh;()];
  / open the file
  .usage.logh:hopen hsym`$logdir,"/",basename;
  };

/ parse a usage log file and return as a usage table
.usage.readlog:{[filename]
  / remove leading backtick from symbol columns, drop "i" suffix from a and w columns and cast back to integers
  :update
    zcmd:`$1_'string zcmd,u:`$1_'string u,a:"I"$-1_'a,w:"I"$-1_'w
    from
    @[{update "J"$'" " vs' mem from flip (cols .usage.usage)!("PJNSC*S***J*";"|")0: x};
      hsym`$filename;
      {'"failed to read log file : ",x}];
  };

/ get the memory info - we don't want to log the physical memory each time
.usage.meminfo:{[] :5#system"w";};

/ format the message handler argument as a string
.usage.formatarg:{[zcmd;arg]
  str:$[10=abs type arg;arg,();.Q.s1 arg];
  / replace %xx hexsequences in HTTP request arguments
  if[zcmd in`ph`pp;str:.h.uh str];
  :str;
  };

/ log the completion of an external request and return the result
.usage.logdirect:{[id;zcmd;endtime;result;arg;starttime]
  if[.usage.level>1;
    .usage.write (starttime;id;endtime-starttime;zcmd;"c";.z.a;.z.u;.z.w;.usage.formatarg[zcmd;arg];.usage.meminfo[];0Nj;"")];
  :result;
  };

/ log stats of query before execution
.usage.logbefore:{[id;zcmd;arg;starttime]
  if[.usage.level>2;
    .usage.write (starttime;id;0Nn;zcmd;"b";.z.a;.z.u;.z.w;.usage.formatarg[zcmd;arg];.usage.meminfo[];0Nj;"")];
  };

/ log stats of a completed query and return the result
.usage.logafter:{[id;zcmd;endtime;result;arg;starttime]
  if[.usage.level>1;
    .usage.write (endtime;id;endtime-starttime;zcmd;"c";.z.a;.z.u;.z.w;.usage.formatarg[zcmd;arg];.usage.meminfo[];-22!result;"")];
  :result;
  };

/ log stats of a failed query and raise the error
.usage.logerror:{[id;zcmd;endtime;arg;starttime;error]
  if[.usage.level>0;
    .usage.write (endtime;id;endtime-starttime;zcmd;"e";.z.a;.z.u;.z.w;.usage.formatarg[zcmd;arg];.usage.meminfo[];0Nj;error)];
  'error;
  };

/ log successful user validation
.usage.logauth:{[zcmd;handler;user;pass]
  :.usage.logdirect[.usage.nextid[];zcmd;.usage.currenttime[.usage.localtime];handler[user;pass];(user;"***");.usage.currenttime[.usage.localtime]];
  };

/ log successful connection opening/closing
.usage.logconnection:{[zcmd;handler;arg]
  :.usage.logdirect[.usage.nextid[];zcmd;.usage.currenttime[.usage.localtime];handler arg;arg;.usage.currenttime[.usage.localtime]];
  };

/ log before and after query execution is attempted
.usage.logquery:{[zcmd;handler;arg]
  id:.usage.nextid[];
  .usage.logbefore[id;zcmd;arg;.usage.currenttime[.usage.localtime]];
  :.usage.logafter[id;zcmd;.usage.currenttime[.usage.localtime];@[handler;arg;.usage.logerror[id;zcmd;.usage.currenttime[.usage.localtime];arg;start;]];arg;start:.usage.currenttime[.usage.localtime]];
  };

/ log before and after query execution is attempted, filtering with .usage.ignoreList
.usage.logqueryfiltered:{[zcmd;handler;arg]
  if[.usage.ignore;
    if[0h=type arg;
      if[any first[arg]~/:.usage.ignorelist;:handler arg]];
    if[10h=type arg;
      if[any arg~/:.usage.ignorelist;:handler arg]]];
  :.usage.logquery[zcmd;handler;arg];
  };

/ initialise .z functions with usage logging functionality
.usage.inithandlers:{[]
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
  .z.pw:.usage.logauth[`pw;.z.pw;;];
  .z.po:.usage.logconnection[`po;.z.po;];
  .z.pc:.usage.logconnection[`pc;.z.pc;];
  .z.wo:.usage.logconnection[`wo;.z.wo;];
  .z.wc:.usage.logconnection[`wc;.z.wc;];
  .z.ws:.usage.logquery[`ws;.z.ws;];
  .z.pg:.usage.logquery[`pg;.z.pg;];
  .z.ps:.usage.logqueryfiltered[`ps;.z.ps;];
  .z.ph:.usage.logquery[`ph;.z.ph;];
  .z.pp:.usage.logquery[`pp;.z.pp;];
  .z.exit:.usage.logquery[`exit;.z.exit;];
  };

/ initialise on disk usage logging, if enabled
.usage.initlog:{[]
  if[.usage.logtodisk;
    if[""in(.usage.logname;.usage.logdir);
      .usage.logtodisk:0b;
      '"logname and logdir must be set to enable on disk usage logging. .usage.logToDisk disabled"];
    .[.usage.createlog;
      (.usage.logdir;.usage.logname;.usage.logtimestamp[.usage.localtime]);
      {.usage.logtodisk:0b;'"Error creating log file: ",.usage.logdir,"/usage_",.usage.logname,"_",string[.usage.logtimestamp[.usage.localtime]]," | Error: " ,x}]];
  };

.usage.init:{[]
  .usage.inithandlers[];
  .usage.initlog[];
  };
