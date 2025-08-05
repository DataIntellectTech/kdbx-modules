/ library for creating and managing stored timer functions

/ override variables to change logic
.timer.debug:0b; / if enabled displays messages for jobs starting and any errors in execution
.timer.logcall:1b; / if enabled will execute timer functions throuhgh 0 handle
.timer.cycletime:100; / frequency to check for new jobs to start (in ms)
.timer.cp:{.z.p}; / return timestamp function used to evaluate start times, can be overwritten for backtesting and simulating

/ in memory table maintaining time functions and scheduling of execution 
.timer.jobs:(
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
.timer.addjob.opts:(`maxruns`maxtime`disableonfail`startattime)!(0Wi;0Wp;1b;0Np);

.timer.addjob.custom:{[id;func;params;period;mode;opts]
  / fully configurable base version of adding a timer job to in memory table
  if[id in key .timer.jobs;'"Cannot add id : ",(string id)," already exists in .timer.jobs"];
  if[-11h=type func;get func];
  opts:.timer.addjob.opts,opts;
  `.timer.jobs insert (id;func;params;.timer.cp[];`int$period;`short$mode;0Np;0Np;0Np;0Np;0i;1b;opts`maxruns;opts`maxtime;opts`disableonfail;opts`startattime);
  $[null (r:.timer.jobs[id])`startattime;
    .timer.upd.start[id];
    [r[`nextstart]:r`startattime;.timer.jobs[id]:r]
    ];
  };

.timer.addjob.default:.timer.addjob.custom[;;;;;()!()];
.timer.addjob.simple:.timer.addjob.custom[;;();;1;()!()];

/ internal utility functions
.timer.msg.custom:{[code;msg]neg[1] (string .timer.cp[])," ### ",code," ### ",msg;};
.timer.msg.info:.timer.msg.custom["INFO";];
.timer.msg.err:.timer.msg.custom["ERROR";];

/ scheduling functions for updating start times and job logic
.timer.upd.start:{[id]r:.timer.jobs[id];.timer.nextstart[r`mode][id;r]};

.timer.upd.status:{[r]
  / updates next run time for job passed on defined mode
  r[`prevend]:.timer.cp[];
  r[`prevstart]:r`nextstart;
  r[`runs]+:1;
  if[(not null r[`maxruns])&r[`maxruns]<=r`runs;r[`status]:0b];
  if[(not null r[`maxtime])&r[`maxtime]<=r`prevend;r[`status]:0b];
  r};

.timer.nextstart:()!();
.timer.nextstart[1h]:{[id;r]
  / updates nextstart to x seconds after previously scheduled start time
  r[`nextstart]:(0D00:00:01*r`period)+$[null r`prevstart;r`created;r`prevstart];
  .timer.jobs[id]:r;
  };
.timer.nextstart[2h]:{[id;r]
  / updates nextstart to x seconds after previous actual start time
  r[`nextstart]:(0D00:00:01*r`period)+$[null r`actualstart;r`created;r`actualstart];
  .timer.jobs[id]:r;
  };
.timer.nextstart[3h]:{[id;r]
  / updates nextstart to x seconds after previous end time
  r[`nextstart]:(0D00:00:01*r`period)+$[null r`prevend;r`created;r`prevend];
  .timer.jobs[id]:r;
  };
.timer.nextstart[4h]:{[id;r]
  / updates nextstart to minute interval next hour after previous start time
  ts:{(`date$x)+(`minute$y)+01:00*`hh$x}[;r`period] pts:$[null r`prevstart;r`created;r`prevstart];
  r[`nextstart]:$[ts>pts;ts;ts+0D01:00:00.000];
  .timer.jobs[id]:r;
  };
.timer.nextstart[5h]:{[id;r]
  / updates nextstart on the hour in x minute intervals after previous start time
  r[`nextstart]:{(`date$x)+y xbar (`minute$y)+`minute$x}[;r`period] $[null r`prevstart;r`created;r`prevstart];
  .timer.jobs[id]:r;
  };

/ utility functions for setting up jobs and monitoring live
.timer.disable:{.timer.enabled:0b};
.timer.enable:{.timer.enabled:1b};

.timer.enablejobs:{[ids] ids:(),ids;.timer.jobs:update status:1b from .timer.jobs where id in ids};
.timer.disablejobs:{[ids] ids:(),ids;.timer.jobs:update status:0b from .timer.jobs where id in ids};
.timer.deletejobs:{[ids] ids:(),ids;.timer.jobs:delete from .timer.jobs where id in ids};

.timer.getactive:{select from .timer.jobs where status};

/ evalution functions for executing jobs and scheduling
.timer.nextruntime:-0Wp;

/ configurable function to alter how timer functions are executed
.timer.execute:{.[{$[count y; x . (),y; x@`];1b};(x;y);{if[.timer.debug;.timer.msg.err"Job execution failed for function: ",(-3!x)," with error: ",y]0b}[x]]};

.timer.runandschedule:{[id]
  / runs function, schedules next runs and updates any additional status info if applicable for given job id
  r:.timer.jobs[id];
  if[.timer.debug;.timer.msg.info"Executing job id: ",(string id)," for start time: ",(string r`nextstart)];
  r[`actualstart]:.timer.cp[];
  ret:@[$[.timer.logcall;0;value];(.timer.execute;r`func;r`params);{if[.timer.debug;.timer.msg.err"Job start failed for job id : ",(string x)," with error: ",y];0b}[id]];
  if[(not ret)&r`disableonfail;r[`status]:0b];
  r:.timer.upd.status[r]; / update status based on job status and configurable options
  .timer.jobs[id]:r;
  if[r[`status];.timer.upd.start[id]]; / update next start time after run
  };

/ cycle functions
.timer.enabled:0b;

.timer.main:{
  / determines what jobs to run
  if[(.timer.nextruntime<p:.timer.cp[])&.timer.enabled;
    torun:exec id from .timer.jobs where status,nextstart<p;
    if[count torun;.timer.runandschedule each torun];
    .timer.nextruntime:exec min[nextstart] from .timer.jobs;
    ];
  };

.timer.init:{
  / appends to any existing .z.ts logic and start system cycle for timer job evaluation
  $[.timer.enabled;:();.timer.enabled:1b]; / bomb out of function if already enabled
  $[@[{value x;1b};`.z.ts;0b]; / test if there is a pre-existing .z.ts definition
    .z.ts:{[x;y] .timer.main y; x@y}[.z.ts];
    .z.ts:{.timer.main x}];
  if[not system"t";system "t ",string .timer.cycletime];
  };
