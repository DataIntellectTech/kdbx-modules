// Library for creating and managing stored timer functions

// Override variables to change logic
.timer.debug:0b; / - if enabled displays messages for jobs starting and any errors in execution
.timer.cycletime:1000; / - frequency to check for new jobs to start (in ms)

// In memory table maintaining time functions and scheduling of execution 
.timer.jobs:(
    [id:`$()]                    / - symbol reference to unique timer functions
    func:();                     / - function to be ran, can be passed as symbol reference or as a function itself
    params:();                   / - function parameters to be passed to function at execution
    created:`timestamp$();       / - timestamp of function initiation
    period:`int$();              / - time period to base timer scheduling on
    mode:`short$();              / - mode to base scheduling logic on 
    prevstart:`timestamp$();     / - scheduled start timestamp of previous run
    actualstart:`timestamp$();   / - start timestamp of previous run
    prevend:`timestamp$();       / - end timestamp of previous run
    nextstart:`timestamp$();     / - timestamp to run next time 
    runs:`int$();                / - running count of number of runs 
    maxruns:`int$();             / - optional flag to disable time function after number of runs
    maxtime:`timestamp$();       / - optional flag to disable job after timestamp
    status:`boolean$();          / - when true job is enabled, false job disabled
    disableonfail:`boolean$()    / - if job fails will disable future runs
    );

// Job functions for adding new functions to be scheduled and executed
.timer.addjob.custom:{[id;func;params;period;mode;maxruns;maxtime;disableonfail]
    if[id in key .timer.jobs;'"Cannot add id : ",(string id)," already exists in .timer.jobs"];
    if[-11h=type func;func:get func];
    `.timer.jobs insert (id;func;params;.z.P;`int$period;`short$mode;0Np;0Np;0Np;0Np;0i;maxruns;maxtime;1b;disableonfail);
    .timer.upd.start[id];
    };
.timer.addjob.simple:.timer.addjob.custom[;;();;1;0Ni;0Np;1b];
.timer.addjob.mode:.timer.addjob.custom[;;;;;0Ni;0Np;1b];

// Internal utility functions
.timer.msg.custom:{[code;msg]0N!(string .z.P)," ### ",code," ### ",msg};
.timer.msg.info:.timer.msg.custom["INFO";];
.timer.msg.err:.timer.msg.custom["ERROR";];

// Scheduling functions for updating start times and job logic
.timer.upd.start:{[id] r:.timer.jobs[id];.timer.nextstart[r`mode][id;r]};

.timer.upd.status:{[r]
    r[`prevend]:.z.P;
    r[`prevstart]:r`nextstart;
    r[`runs]+:1;
    if[(not null r[`maxruns])&r[`maxruns]<=r`runs;r[`status]:0b];
    if[(not null r[`maxtime])&r[`maxtime]<=r`prevend;r[`status]:0b];
    r};

.timer.nextstart:()!();
.timer.nextstart[1h]:{[id;r]
    r[`nextstart]:(0D00:00:01*r`period)+$[null r`prevstart;r`created;r`prevstart];
    .timer.jobs[id]:r;
    };
.timer.nextstart[2h]:{[id;r]
    r[`nextstart]:(0D00:00:01*r`period)+$[null r`actualstart;r`created;r`actualstart];
    .timer.jobs[id]:r;
    };
.timer.nextstart[3h]:{[id;r]
    r[`nextstart]:(0D00:00:01*r`period)+$[null r`prevend;r`created;r`prevend];
    .timer.jobs[id]:r;
    };
.timer.nextstart[4h]:{[id;r]
    ts:{(`date$x)+(`minute$y)+01:00*`hh$x}[;r`period] pts:$[null r`prevstart;r`created;r`prevstart];
    r[`nextstart]:$[ts>pts;ts;ts+0D01:00:00.000];
    .timer.jobs[id]:r;
    };
.timer.nextstart[5h]:{[id;r]
    r[`nextstart]:{(`date$x)+y xbar (`minute$y)+`minute$x}[;r`period] $[null r`prevstart;r`created;r`prevstart];
    .timer.jobs[id]:r;
    };

// Utility functions for setting up jobs and monitoring live
.timer.disable:{
    if[0=system"t";.timer.msg.info".z.ts not enabled... doing nothing";:()];
    $[{}~.timer.dotz.orig;system"t 0";.z.ts:.timer.dotz.orig];
    };

.timer.enablejobs:{[ids] ids:(),ids;.timer.jobs:update status:1b from .timer.jobs where id in ids};
.timer.disablejobs:{[ids] ids:(),ids;.timer.jobs:update status:0b from .timer.jobs where id in ids};
.timer.deletejobs:{[ids] ids:(),ids;.timer.jobs:delete from .timer.jobs where id in ids};

.timer.getactive:{[id] select from .timer.jobs where status};

// Evalution functions for executing jobs and scheduling
.timer.runandschedule:{[id]
    r:.timer.jobs[id];
    if[.timer.debug;.timer.msg.info"Executing job id: ",(string id)," for start time: ",(string r`nextstart)];
    r[`actualstart]:.z.P;
    ret:$[count r`params;
        .[r`func;(),r`params;{.timer.msg.err"Job execution failed with error : ",x;0b}];
        @[r`func;`;{.timer.msg.err"Job execution failed with error : ",x;0b}]
        ];
    if[not -1h=type ret;ret:1b];
    if[not ret;
        if[.timer.debug;.timer.msg.err"Job execution failed for job id : ",(string id)];
        if[r`disableonfail;r[`status]:0b];
        ];
    r:.timer.upd.status[r];
    .timer.jobs[id]:r;
    if[r[`status];.timer.upd.start[id]];
    };

// Cycle functions
.timer.main:{
    torun:exec id from .timer.jobs where status,nextstart<.z.P;
    if[count torun;.timer.runandschedule each torun];
    };

.timer.init:{
    .timer.dotz.orig:@[get;`.z.ts;{}];
    .z.ts:$[{}~.timer.dotz.orig;.timer.main;{.timer.dotz.orig`;.timer.main`}];
    if[not system"t";system "t ",string .timer.cycletime];
    };
