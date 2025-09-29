## KDB+/Q Timer Function Library

A lightweight, customizable timer management library in kdb+/q for scheduling and executing time-based functions. This module supports fixed-interval scheduling, job metadata tracking, conditional disabling, and debug logging — ideal for systems requiring timed task orchestration.

---

### Features
- Register arbitrary functions with scheduling parameters
- Support for passing execution arguments to functions
- Five execution modes for timing alignment
- Tracks both scheduled and actual run timestamps
- Auto-disable based on time or run limits
- Control job activation, status, and failure handling
- Toggleable logging for development and troubleshooting

---


### Core Concepts
Timer jobs are tracked in **t.jobs**, an in-memory table storing job metadata:

| Column        | Type      | Description                                                           |
| ------------- | --------- | --------------------------------------------------------------------- |
| id            | symbol    | Unique function identifier                                            |
| func          | function  | Function to be executed, passed as a definition or symbol reference   |
| params        | list      | Parameters passed to the function if required                         |
| created       | timestamp | Time job was registered                                               |
| period        | int       | scheduling interval in seconds or minutes depending on mode           |
| mode          | short     | Scheduling mode for computing run times, see "Execution Mode" section |
| prevstart     | timestamp | Scheduled time of previous run                                        |
| actualstart   | timestamp | Actual start time of previous run                                     |
| prevend       | timestamp | End time of previous run                                              |
| nextstart     | timestamp | time of next scheduled run                                            |
| runs          | int       | Count of successful executions                                        |
| status        | boolean   | Whether job is active (1b) or disabled (0b)                           |
| maxruns       | int       | Max number of runs before job is disabled                             |
| maxtime       | timestamp | Cutoff time for job scheduling                                        |
| disableonfail | boolean   | Flag to disable job on failure if enabled                             |
| startattime   | timestamp | Start specifically at provided time                                   |  

---

### Execution Mode
Timer jobs use one of five scheduling modes, defined by the mode column:

| Mode     | Scheduling Logic                                             | Example                       |
| -------- | ------------------------------------------------------------ | ----------------------------- |
| 1        | Jobs scheduled x seconds after previous scheduled start time |                               |
| 2        | Jobs scheduled x seconds after previous actual start time    |                               |
| 3        | Jobs scheduled x seconds after previous end time             |                               |
| 4        | Jobs scheduled for the xth minute of every hour              | x = 10 : 13:10,14:10,15:10... |
| 5        | Jobs scheduled on the hour and in x minute intervals         | x = 15 : 13:00,13:15,13:30... |

---

### Adding Jobs
Functions shown below allow you to register new timer-based jobs with varying degrees of customization — ranging from full control over scheduling, parameters, and failure handling to simplified shortcuts for common use cases.

###### Function Parameters

| Parameter     | Type       | Description                                                           |
| ------------- | ---------- | --------------------------------------------------------------------- |
| id            | symbol     | Unique function identifier, must not already exist in t.jobs     |
| func          | function   | Function to be executed when job runs                                 |
| params        | list       | Arguments to pass into the function at run time                       |
| period        | int        | Time period in seconds or minutes for next run time calculations      |
| mode          | short      | Scheduling more to determine next run time                            |
| opts          | dictionary | Optional additional configuration parameters, specifics below         |

###### Function Options
| Option        | Type      | Description                                                   |
| ------------- | --------- | ------------------------------------------------------------- |
| maxruns       | int       | Number of times for function to execute before being disabled |
| maxtime       | timestamp | Max timestamp for new function executions to be scheduled     |
| disableonfail | boolean   | By default: 1b, will automatically disable jobs if they fail  |
| startattime   | timestmap | Specfic timestamp for intial function run                     |

#### t.addjob.custom
Lets you fully define a scheduled job by specifying its function, parameters, timing, mode, and options.
```q
t.addjob.custom[`job1;{show x};("Hello!");10;4;(enlist `maxruns)!(enlist 3)];
t.addjob.custom[`job2;{show x+y};(2;3);15;5;(`maxtime`startattime)!(2025.07.30D17:00:000;2025.07.30D09:00:000)];
t.addjob.custom[`job3;{show "Hello, world!"};5;1;()!()];
```

#### t.addjob.default
Streamlined way to create a simple job with set default options i.e. not maxruns,maxtime or startattime and will automically disable on fail
```q
t.addjob.default[`job4;{show "Mode 2"};();15;2];
```

#### t.addjob.simple 
Provides a fast way to schedule a job using sensible defaults — ideal for quick setup when you only need to specify a function, its interval, and minimal configuration. Schedule mode is defaulted to 1.
```q
t.addjob.simple[`job5;{show "Hi"};30]
```

---

### Control & Monitoring
The timer system includes a suite of control functions that let you start, stop, and inspect timer jobs with precision. These utility functions ensure operational flexibility while maintaining the integrity of the scheduling loop.

#### t.init
```q
t.init[]
```
- Purpose: Initializes the timer scheduler by hooking .z.ts to t.main[].
- Effect: Establishes a recurring loop that checks for jobs due to run based on t.cycletime. If .z.ts is already defined, it safely preserves and wraps it.
- Usage: Call once when starting your timer system or restarting after t.disable[].

#### t.disable
```q
t.disable[]
```
- Purpose: Stops the timer execution loop by restoring the original .z.ts handler.
- Effect: Prevents t.main[] from being automatically triggered, effectively pausing scheduled job execution.
- Safety: Checks if .z.ts was previously saved before attempting to revert it.
- Usage: Useful during maintenance, debugging, or when manually controlling job flow

#### t.enablejobs
```q
t.enablejobs[`job1]
t.enablejobs[`job1`job2]
```
- Purpose: Reactivates one or more jobs by setting status:1b in t.jobs.
- Usage: Accepts a single symbol or list of job IDs. Jobs will resume scheduling and execution as normal.

#### t.disablejobs
```q
t.disablejobs[`job3]
t.disablejobs[`job4`job5]
```
- Purpose: Deactivates one or more jobs by setting status:0b, preventing them from being picked up by the scheduler.
- Usage: Ideal for temporarily suspending jobs without deleting their metadata.

#### t.deletejobs
```q
t.deletejobs[`job3]
t.deletejobs[`job4`job5]
```
- Purpose: Removes jobs from t.jobs table. Can be done without disabling loop.
- Usage: Ideal for re-defining job params wihtout interrupting other jobs.


#### t.getactive
```q
t.getactive[]
```
- Purpose: Queries t.jobs and returns all currently active jobs (status=1b).
- Output: Returns a table of job rows, allowing inspection of current scheduling, metadata, and run statistics.
- Usage: Useful for dashboarding, monitoring job health, or debugging live workflows

---

### User Customisations
These are global control variables and can be adjusted by the user after import before initializing with t.init.
#### Debug
```q
t.debug:1b
```
- Purpose: Enables verbose logging for job execution.
- Type: Boolean (1b for enabled, 0b for disabled).
- Usage: When set to 1b, job execution attempts, successes, and errors will be logged to the console with timestamps and context via t.msg.info and t.msg.err.
- Default: 0b (disabled).
This is useful during development or troubleshooting to inspect scheduler behavior.
#### Log Call
```q
t.logcall:1b
```
- Purpose: Logs function execution in usage logs through 0 handle.
- Type: Boolean (1b for enabled, 0b for disabled).
- Usage: Enables 0 handle logging for tracking function exection. 
Default: 1b (enabled)
This is useful for production use to ensure application is operating as expected 
#### Cycle Time
```q
t.cycletime:1000
```
- Purpose: Sets the interval (in milliseconds) between scheduler checks for jobs that are due to run.
- Type: Integer.
- Usage: Controls how frequently .z.ts triggers the main execution loop t.main[].
- Default: 1000 (1 second).
Adjust this value to increase responsiveness or reduce CPU usage, depending on the expected job timing precision.
#### Current Timestamp
```q
t.cp:{.z.p}
```
- Purpose: Internal function defined for returning timestamps for all internal logic
- Type: Function, returns timestamp
- Usage: Allows the user to overwrite all internal timestamps used for scheduling
- Default: {.z.p}
This is useful for backtesting and simulation

### Example 
```q
\l timer.q / - package import process may change, just for example

t.cycletime:500;

helloFunc:{show "Hello from job 1"};
t.addjob.simple[`job1;helloFunc;5];

echoFunc:{show x};
t.addjob.custom[`job2;echoFunc;enlist "Echo this!";10;2;(enlist `maxruns)!(enlist 3)];

.func.timeAligned:{show "On the quarter hour"};
t.addjob.default[`job3;`.func.timeAligned;();15;5];

t.init[];

// Enable and disable jobs manually if needed
t.disablejobs[`job3]
t.enablejobs[`job3]

// View all active jobs
t.getactive[]

// Temporarily halt job execution
t.disable[]

// Restart scheduler loop again later
t.enable[]
``````
