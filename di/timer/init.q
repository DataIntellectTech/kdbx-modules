/ library for creating and managing stored timer functions

/ return timestamp function used to evaluate start times, can be overwritten for backtesting and simulating
cp:{.z.p}; 

/ in memory table maintaining time functions and scheduling of execution 
jobs:(
  [id:`$()]                    / symbol reference to unique timer functions
  func:();                     / function to be ran, can be passed as symbol reference or as a function itself
  params:();                   / function parameters to be passed to function at execution
  created:`timestamp$();       / timestamp of function initiation
  period:`int$();              / time period to base timer scheduling on
  mode:`short$();              / mode to base scheduling logic on 
  prevstart:`timestamp$();     / scheduled start timestamp of previous run
  actualstart:`timestamp$();   / start timestamp of previous run
  prevend:`timestamp$();       / end timestamp of previous run
  nextstart:`timestamp$();     / timestamp to run next time
  runs:`int$();                / running count of number of runs
  status:`boolean$();          / when true job is enabled, false job disabled
  maxruns:`int$();             / optional flag to disable time function after number of runs 
  maxtime:`timestamp$();       / optional flag to disable job after timestamp
  disableonfail:`boolean$();   / if job fails will disable future runs
  startattime:`timestamp$()    / optional custom start time to run for the first time
  );

/ job functions for adding new functions to be scheduled and executed
addjob.opts:(`maxruns`maxtime`disableonfail`startattime)!(0Wi;0Wp;1b;0Np);

addjob.custom:{[id;func;params;period;mode;opts]
  / fully configurable base version of adding a timer job to in memory table
  if[id in key .z.M.jobs;'"Cannot add id : ",(string id)," already exists in jobs"];
  if[-11h=type func;get func];
  opts:addjob.opts,opts;
  .z.M.jobs insert (id;func;params;cp[];`int$period;`short$mode;0Np;0Np;0Np;0Np;0i;1b;`int$(opts`maxruns);opts`maxtime;opts`disableonfail;opts`startattime);
  $[null (r:.z.M.jobs[id])`startattime;
    upd.start[id];
    [r[`nextstart]:r`startattime;@[.z.M.jobs;id;:;r]]
    ];
  };

addjob.default:addjob.custom[;;;;;()!()];
addjob.simple:addjob.custom[;;();;1;()!()];

/ internal utility functions
msg.custom:{[code;msg]neg[1] (string cp[])," ### ",code," ### ",msg;};
msg.info:msg.custom["INFO";];
msg.err:msg.custom["ERROR";];

/ scheduling functions for updating start times and job logic
upd.start:{[id]r:.z.M.jobs[id];nextstart[r`mode][id;r]};

upd.status:{[r]
  / updates next run time for job passed on defined mode
  r[`prevend]:cp[];
  r[`prevstart]:r`nextstart;
  r[`runs]+:1;
  if[(not null r[`maxruns])&r[`maxruns]<=r`runs;r[`status]:0b];
  if[(not null r[`maxtime])&r[`maxtime]<=r`prevend;r[`status]:0b];
  r};

nextstart:()!();
nextstart[1h]:{[id;r]
  / updates nextstart to x seconds after previously scheduled start time
  r[`nextstart]:(0D00:00:01*r`period)+$[null r`prevstart;r`created;r`prevstart];
  @[.z.M.jobs;id;:;r];
  };
nextstart[2h]:{[id;r]
  / updates nextstart to x seconds after previous actual start time
  r[`nextstart]:(0D00:00:01*r`period)+$[null r`actualstart;r`created;r`actualstart];
  @[.z.M.jobs;id;:;r];
  };
nextstart[3h]:{[id;r]
  / updates nextstart to x seconds after previous end time
  r[`nextstart]:(0D00:00:01*r`period)+$[null r`prevend;r`created;r`prevend];
  @[.z.M.jobs;id;:;r];
  };
nextstart[4h]:{[id;r]
  / updates nextstart to minute interval next hour after previous start time
  ts:{(`date$x)+(`minute$y)+01:00*`hh$x}[;r`period] pts:$[null r`prevstart;r`created;r`prevstart];
  r[`nextstart]:$[ts>pts;ts;ts+0D01:00:00.000];
  @[.z.M.jobs;id;:;r];
  };
nextstart[5h]:{[id;r]
  / updates nextstart on the hour in x minute intervals after previous start time
  r[`nextstart]:{(`date$x)+y xbar (`minute$y)+`minute$x}[;r`period] $[null r`prevstart;r`created;r`prevstart];
  @[.z.M.jobs;id;:;r];
  };

/ utility functions for setting up jobs and monitoring live
disable:{.[.z.M.enabled;();:;0b];};
enable:{.[.z.M.enabled;();:;1b];};

enablejobs:{[ids] ids:(),ids;.z.m.jobs:update status:1b from .z.m.jobs where id in ids};
disablejobs:{[ids] ids:(),ids;.z.m.jobs:update status:0b from .z.m.jobs where id in ids};
deletejobs:{[ids] ids:(),ids;.z.m.jobs:delete from .z.m.jobs where id in ids};

getactivejobs:{select from .z.m.jobs where status};

getalljobs:{ :.z.m.jobs}

/ evalution functions for executing jobs and scheduling
nextruntime:-0Wp;

/ configurable function to alter how timer functions are executed
execute:{.[{$[count y; x . (),y; x@`];1b};(x;y);{if[debug;msg.err"Job execution failed for function: ",(-3!x)," with error: ",y]0b}[x]]};

runandschedule:{[id]
  / runs function, schedules next runs and updates any additional status info if applicable for given job id
  r:.z.M.jobs[id];
  if[debug;msg.info"Executing job id: ",(string id)," for start time: ",(string r`nextstart)];
  r[`actualstart]:cp[];
  ret:@[$[logcall;0;value];(execute;r`func;r`params);{if[debug;msg.err"Job start failed for job id : ",(string x)," with error: ",y];0b}[id]];
  if[(not ret)&r`disableonfail;r[`status]:0b];
  r:upd.status[r]; / update status based on job status and configurable options
  @[.z.M.jobs;id;:;r];
  if[r[`status];upd.start[id]]; / update next start time after run
  };

/ cycle functions
enabled:0b;

main:{
  / determines what jobs to run
  if[(nextruntime<p:cp[])&enabled;
    torun:exec id from .z.m.jobs where status,nextstart<p;
    if[count torun;runandschedule each torun];
    .z.m.nextruntime:exec min[nextstart] from .z.m.jobs;
    ];
  };

setcp:{.z.m.cp: x};

init:{[configs]
  / sets default config vars
  .z.m.debug:0b; / if enabled displays messages for jobs starting and any errors in execution
  .z.m.logcall:1b; / if enabled will execute timer functions through 0 handle
  .z.m.cycletime:100; / frequency to check for new jobs to start (in ms)

  / set custom config vars
  if[not configs~(::);
    vars:`logcall`cycletime`debug inter key configs;
    (.Q.dd[.z.M] each key[vars#configs]) set' value[vars#configs];
  ];
  / appends to any existing .z.ts logic and start system cycle for timer job evaluation
  $[enabled;:();.z.m.enabled:1b]; / bomb out of function if already enabled
  $[@[{value x;1b};`.z.ts;0b]; / test if there is a pre-existing .z.ts definition
    .z.ts:{[x;y] main y; x@y}[.z.ts];
    .z.ts:{main x}];
  if[not system"t";system "t ",string cycletime];
  };


export:([init;getactivejobs;getalljobs;addjob;deletejobs;enablejobs;disablejobs;enable;disable;setcp])
