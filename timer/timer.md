## KDB+/Q Timer Function Library

A lightweight, customizable timer management library in kdb+/q for scheduling and executing time-based functions. This module supports fixed-interval scheduling, job metadata tracking, conditional disabling, and debug logging—ideal for systems requiring timed task orchestration.

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
Timer jobs are tracked in ```.timer.procs``` an in-memory table storing job metadata:

| Column        | Type      | Description                                                           |
| ------------- | --------- | --------------------------------------------------------------------- |
| id            | symbol    | Unique function identifier                                            |
| func          | function  | Function to be executed                                               |
| params        | list      | Parameters passed to the function if required                         |
| created       | timestamp | Time job was registered                                               |
| period        | int       | scheduling interval in seconds or minutes depending on mode           |
| mode          | short     | Scheduling mode for computing run times, see "Execution Mode" section |
| prevstart     | timestamp | Scheduled time of previous run                                        |
| actualstart   | timestamp | Actual start time of previous run                                     |
| prevend       | timestamp | End time of previous run                                              |
| nextstart     | timestamp | time of next scheduled run                                            |
| runs          | int       | Count of successful executions                                        |
| maxruns       | int       | Max number of runs before job is disabled                             |
| maxtime       | timestamp | Cutoff time for job scheduling                                        |
| status        | boolean   | Whether job is active (1b) or disabled (0b)                           |
| disableonfail | boolean   | Flag to disable job on failure if enabled                             |  

---

### Execution Mode
Timer jobs use one of four scheduling modes, defined by the mode column:

| Mode     | Scheduling Logic                                             | Example                       |
| -------- | ------------------------------------------------------------ | ----------------------------- |
| 1        | Jobs scheduled x seconds after previous scheduled start time |                               |
| 2        | Jobs scheduled x seconds after previous actual start time    |                               |
| 3        | Jobs scheduled x seconds after previous end time             |                               |
| 4        | Jobs scheduled for the xth minute of every hour              | x = 10 : 13:15,14:15,15:15... |
| 5        | Jobs scheduled on the hour in x minute intervals             | x = 15 : 13:00,13:15,13:30... |

---

### Usage .timer.addjob
Functions allow you to register new timer-based jobs with varying degrees of customization—ranging from full control over scheduling, parameters, and failure handling to simplified shortcuts for common use cases.

| Parameter     | Type      | Description                                                           |
| ------------- | --------- | --------------------------------------------------------------------- |
| id            | symbol    | Unique function identifier, must not already exist in .timer.procs    |
| func          | function  | Function to be executed when job runs                                 |
| params        | list      | arguments to pass into the function at run time                       |
| period        | int       | Time period in seconds or minutes for next run time calculations      |
| mode          | short     | Scheulding more to determine next run time                            |
| maxruns       | int       | Optional limit on nnumber of times the job may run. 0Ni to disables   |
| maxtime       | timestamp | Optional timestamp after which the job becomes inactive, 0Np disables |
| disableonfail | boolean   | If set to 1b, disables future runs if the function fails to execute   |

##### .timer.addjob.custom
Lets you fully define a scheduled job by specifying its function, parameters, timing, mode, and control flags for execution limits and failure handling.
```
.timer.addjob.custom[`job1;{show x};("Hello!");10;1;5;0Np;1b]
```

##### .timer.addjob.simple 
Provides a fast way to schedule a job using sensible defaults—ideal for quick setup when you only need to specify a function, its interval, and minimal configuration. Schedule mode is defaulted to 1.
```
.timer.addjob.simple[`job2;{show "Hi"};30]
```

##### .timer.addjob.mode 
Streamlined way to create a simple job with custom mode and parameters while applying default safeguards for failure handling and execution limits.
```
.timer.addjob.mode[`job3;{show "Mode 2"};();15;2]
```

---

### Control & Monitoring
The timer system includes a suite of control functions that let you start, stop, and inspect timer jobs with precision. These utility functions ensure operational flexibility while maintaining the integrity of the scheduling loop.

##### .timer.init
```
.timer.init[]
```
- Purpose: Initializes the timer scheduler by hooking .z.ts to .timer.main[].
- Effect: Establishes a recurring loop that checks for jobs due to run based on .timer.cycletime. If .z.ts is already defined, it safely preserves and wraps it.
- Usage: Call once when starting your timer system or restarting after .timer.disable[].

##### .timer.disable
```
.timer.disable[]
```
- Purpose: Stops the timer execution loop by restoring the original .z.ts handler.
- Effect: Prevents .timer.main[] from being automatically triggered, effectively pausing scheduled job execution.
- Safety: Checks if .z.ts was previously saved before attempting to revert it.
- Usage: Useful during maintenance, debugging, or when manually controlling job flow

##### .timer.enablejobs
```
.timer.enablejobs[`job1]
.timer.enablejobs[`job1`job2]
```
- Purpose: Reactivates one or more jobs by setting status:1b in .timer.procs.
- Usage: Accepts a single symbol or list of job IDs. Jobs will resume scheduling and execution as normal.

##### .timer.disablejobs
```
.timer.disablejobs[`job3]
.timer.disablejobs[`job4`job5]
```
- Purpose: Deactivates one or more jobs by setting status:0b, preventing them from being picked up by the scheduler.
- Usage: Ideal for temporarily suspending jobs without deleting their metadata.

##### .timer.deletejobs
```
.timer.deletejobs[`job3]
.timer.deletejobs[`job4`job5]
```
- Purpose: Removes jobs from .timer.procs table. Can be done without disabling loop.
- Usage: Ideal for re-defining job params wihtout interrupting other jobs.


##### .timer.getactive
```
.timer.getactive[]
```
- Purpose: Queries .timer.procs and returns all currently active jobs (status=1b).
- Output: Returns a table of job rows, allowing inspection of current scheduling, metadata, and run statistics.
- Usage: Useful for dashboarding, monitoring job health, or debugging live workflows

---

### User Customisations
These are global control variables and can be adjusted by the user after import before initializing with .timer.init.
#### Debug
```
.timer.debug:1b
```
- Purpose: Enables verbose logging for job execution.
- Type: Boolean (1b for enabled, 0b for disabled).
- Usage: When set to 1b, job execution attempts, successes, and errors will be logged to the console with timestamps and context via .timer.msg.info and .timer.msg.err.
- Default: 0b (disabled).
This is useful during development or troubleshooting to inspect scheduler behavior.
#### Cycle Time
```
.timer.cycletime:1000
```
- Purpose: Sets the interval (in milliseconds) between scheduler checks for jobs that are due to run.
- Type: Integer.
- Usage: Controls how frequently .z.ts triggers the main execution loop .timer.main[].
- Default: 1000 (1 second).
Adjust this value to increase responsiveness or reduce CPU usage, depending on the expected job timing precision.

### Example 
```
\l timer.q / - package import process may change, just for example

.timer.cycletime:500;

helloFunc:{show "Hello from job 1"};
.timer.addjob.simple[`job1; helloFunc; 5]; / Runs every 5 seconds

echoFunc:{show x};
.timer.addjob.custom[`job2;echoFunc;enlist "Echo this!";10;2;3;0Np;1b];

timeAligned:{show "On the quarter hour"};
.timer.addjob.mode[`job3;timeAligned;();15;5];

.timer.init[];

/ Enable and disable jobs manually if needed
.timer.disablejobs[`job3]
.timer.enablejobs[`job3]

/ View all active jobs
.timer.getactive[]

/ Temporarily halt job execution
.timer.disable[]

/ Restart scheduler loop again later
.timer.init[]
```