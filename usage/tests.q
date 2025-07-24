\l usage.q

// ----- utils -----

.test.opts:.Q.opt .z.x;
.test.debug:"B"$first first .Q.opt`debug;

.test.res:enlist`name`pass`fn`args`ex!(`;1b;"";"";"")

// simple logging function
// x  {string}  Message to log.
.test.log:{[x]
  -1 string[.z.t]," - ",x
  };

// runs a test and verifies against expected result
// name {sym}     test name
// fn   {sym|fn}  function to run
// args {any}     Input to funcion
// ex   {any}     Expected result
.test.run:{[name;fn;args;ex]
  .test.prun[name;fn;.test.dotorat[fn][fn;];args;ex;~];
  };

// runs a test and verifies that it throws the expected error
// name {sym}     test name
// fn   {sym|fn}  function to run
// args {any}     Input to funcion
// err  {string}  Expected error (can contain regex)
.test.err:{[name;fn;args;err]
  .test.prun[name;fn;.test.dotorat[fn][fn;;::];ex;like]
  };

// private run function
// name {sym}     test name
// fn   {sym|fn}  raw function (used only to append to results table
// wfn  {fn}      monadic wrapped function (the thing we'll actually run)
// args {any}     function args
// ex   {any}     Expected result
// vfn  {fn}      dyadic verification function we use to verify actual result vs. expected
.test.prun:{[name;fn;wfn;args;ex;vfn]
  act:wfn args;
  res:vfn[act;ex];
  .test.log"Test result: name=",string[name]," pass=",res;
  if[.test.debug&not res;{'"test failed"}[]]; / Break here to allow easier debugging
  .test.res,:(name;fn;args;act;ex);
  };

.test.mock:

.test.unmock:

.test.dotorat:{[fn]

  };

// ----- tests -----

// --- init ---

// init should set handlers (default) implementation and skip disk logging.

// init should use custom handler logic and skip logging.

// init should error if log name/dir not set.

// init should error if log file creation fails.

// init should successfully log to disk.

// --- log read/write ---
