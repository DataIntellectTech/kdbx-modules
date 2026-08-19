/ define default config
default:(
  `targetsize`maxfactor`splitoversized`calibrate`compressionratio,
  `symcol`timecol`presort`rowgroupbytes`codec`complevel`dictcols,
  `parallel`outdir`filestub
  )!(
  512*1024*1024;                 / ~512 MB target file size
  1.5;                           / hard cap = target * maxfactor
  1b;                            / split instruments larger than the cap
  1b;                            / run a calibration write to set the ratio
  0.30;                          / raw->parquet ratio if not calibrating
  `sym;                          / instrument column
  `time;                         / time column
  1b;                            / sort by (sym,time) if not already
  128*1024*1024;                 / ~128 MB row groups
  `zstd;                         / codec
  3;                             / compression level
  `sym`exchange;                 / dictionary-encode these columns
  0b;                            / write files via peach
  `:.;                           / output directory
  "part"                         / file name stub
  );

/ define empty schema for manifest
manifest:([]
  file     :`symbol$();    / path written
  seq      :`long$();      / sequence number within the partition
  syms     :();            / list of instruments in the file
  nsyms    :`long$();      / count of instruments
  rows     :`long$();      / row count
  mintime  :`timestamp$(); / min time across the file (for pruning)
  maxtime  :`timestamp$(); / max time across the file
  estbytes :`long$();      / estimated size at plan time
  bytes    :`long$();      / actual on-disk size
  split    :`boolean$();   / true if this file is a chunk of a split oversized instrument
  status   :`symbol$()     / `ok | `error
  );

checkandconvertcols:{[t]
  / takes a table and checks whether any symbol or char columns exist in it
  / if so, converts these to strings, as no Parquet datatype equivalent
  :$[count c:exec c from meta[t] where t in "Ssc";
    ![t;();0b;c!{(string;x)} each c];
    t
  ]
 };

estimate:{[t;o;writeopt]
  / for a partition of data, estimates the size of the tables to be saved to disk
  / if calibrate flag is true in o, a test write is carried out
  / returns a table of storage stats for all instruments and the compression ratio, which may have changed depending on calibration
  cnts:`rowcnt xasc 0!?[t;();enlist[o[`symcol]]!enlist[o[`symcol]];enlist[`rowcnt]!enlist(count;o[`timecol])]; / select rowcnt:count time by sym from t, using appropriate substitutions for time and sym cols
  medsym:cnts @ first where abs[cnt-med[cnt]]=min[abs[cnt-med[cnt:cnts`rowcnt]]];
  bytesperrow:%[-22!t:.z.m.checkandconvertcols t[where t[o[`symcol]]=medsym[o[`symcol]]];medsym`rowcnt];

  / calibrate compression ratio if option is enabled
  if[o`calibrate;
    .z.m.loginfo[`pqx;"Calibrating compression ratio"];
    o[`compressionratio]:.z.m.calibrateratio[t;o;writeopt]
  ];

  / return stats and (new) compression ratio
  :(update estbyt:rowcnt*bytesperrow*o[`compressionratio] from cnts;o[`compressionratio])
 };

calibrateratio:{[t;o;writeopt]
  / writes a sample of data to disk and reads its size on disk
  / calculates the compression ratio and returns if a new ratio was successfully calculated, otherwise old ratio is maintained

  / remove leading : from outdir
  testloc:$[":" ~ first string[o`outdir];
    1_string[o`outdir],"/testWrite.parquet";
    string[o`outdir],"/testWrite.parquet"];

  / outputs two items - success flag and any error msg
  .z.m.loginfo[`pqx;"Attempting test write of median sym for calibration"];
  res:.z.m.tryfn[`.m.di.0pqx.arrow.pq.writeParquetFromTable;(testloc;t;writeopt)];

  / if error returned in first item of res, just return old compression ratio
  if[not first res;
    .z.m.logwarn[`pqx;"Calibration write unsuccessful. Error - ",last res];
    .z.m.logwarn[`pqx;"Returning existing compression ratio"];
    :o`compressionratio
  ];

  .z.m.loginfo[`pqx;"Test write successful"];

  sizeondisk:hcount hsym `$testloc;
  newratio:sizeondisk % -22!t;

  / clean test file
  .z.m.loginfo[`pqx;"Cleaning up test file"];
  system "rm ",testloc;

  / return new ratio
  .z.m.loginfo[`pqx;"Returning calibrated compression ratio"];
  :newratio
 };

calcsize:{[tbl;symcol;syms;seqno]
  / find the estimated size in bytes for each instrument per file to be saved down
  / in the case of a larger instrument being split, return count[seqno] number of instances of estbytes
  .z.m.loginfo[`pqx;"Getting estimated bytes for planned files"];
  :"j"$count[seqno]#%[sum[?[tbl;enlist(in;symcol;enlist syms);0b;()]`estbyt];count seqno]
 };

plan:{[t;o;maxsize]
  / planning function to bucket instruments based on next-fit packing
  / if an instrument can be added to a bucket without that bucket exceeding the target size, it will be added to that bucket
  / else a new bucket is created
  / large instruments are also split into multiple files if splitoversized flag is true
  symstats:t;
  plans:();

  / if split oversized is required, check against maxsize and return a plan entry for each required file
  if[o`splitoversized;
    .z.m.loginfo[`pqx;"Splitting large instruments"];
    t:update islargerthantargetsize:estbyt>maxsize from t;
    oversized:select from t where islargerthantargetsize;
    t:t except oversized;
    oversized:update numfiles:ceiling[estbyt%maxsize] from oversized;
    plans,:enlist each raze {[t;c] t[`numfiles]#enlist t[c]}[;o`symcol] each oversized
  ];

  / next fit function for packing instruments into buckets if they conform to the max size
  if[count t;
    .z.m.loginfo[`pqx;"Bucketing small instruments"];
    tabs:t[o[`symcol]];
    sizes:t`estbyt;
    n:count tabs;

    step:{[maxsize;sizes;state;i]
      sz:sizes i;
      tot:state 1;
      $[(tot+sz)>maxsize; (1+state 0; sz); (state 0; tot+sz)]
    }[maxsize;sizes];
    bins: (step\[(0;0);til n])[;0];

    plans,:value[tabs @ group bins]
  ];
  plans:(1 + til count plans)!plans;

  / attach estbytes to plan's output
  :update estbytes:.z.m.calcsize[symstats;o`symcol;;]'[syms;seqno] from {`syms`seqno!/: flip (key[x];value[x])} group plans
 };

datalookup:{[t;symcol;syms;cnt]
  / get lists of indices by file
  / a pass with multiple instruments is assumed to be one file only, hence the return is flattened into one list
  $[1<count syms;
    :enlist[raze/[.z.m.datalookuponesym[t;symcol;;cnt] each syms]];
    :.z.m.datalookuponesym[t;symcol;first[syms];cnt]
  ]
 };

datalookuponesym:{[t;symcol;sym;cnt]
  / finds indices where instrument occurs in table partition, and cuts into lists if the result set is to be split
  :ceiling [%[count[where t[symcol] in sym];cnt]] cut where t[symcol] in sym
 };

writefile:{[t;o;writeopt;writedir;map]
  / writes data to disk in Parquet format
  / returns stats to be inserted into the manifest
  syms:map[`syms];
  seqno:map[`seqno];
  estbytes:map[`estbytes];

  / build paths for each seqno
  paths:writedir,/:o[`filestub],/:"-",/:("0"^-5$string[seqno]),\:".parquet";

  / data to write, iterated by file
  res:raze {[t;o;writeopt;split;path;seqno;estbytes;i]
    .z.m.loginfo[`pqx;"Writing seqNo ",string[seqno],", path - ",path];
    res:.z.m.tryfn[`.m.di.0pqx.arrow.pq.writeParquetFromTable;(path;.z.m.checkandconvertcols t[i];writeopt)];
    $[first res;
      .z.m.loginfo[`pqx;"seqNo ",string[seqno]," write successful"];
      .z.m.logwarn[`pqx;"seqNo ",string[seqno]," write unsuccessful. Error - ",last res]
    ];
    :`file`seq`syms`nsyms`rows`mintime`maxtime`estbytes`bytes`split`status!/: flip (
      hsym `$path;
      seqno;
      enlist distinct[t[i][o`symcol]];
      count[distinct[t[i][o`symcol]]];
      count[i];
      first ?[t[i];();();(min;o`timecol)];
      first ?[t[i];();();(max;o`timecol)];
      estbytes;
      @[hcount;hsym `$path;0];
      split;
      `error`ok[first res]
    )
  }[t;o;writeopt;1<count seqno;;;]'[paths;seqno;estbytes;.z.m.datalookup[t;o`symcol;syms;count seqno]];

  :res
 };

tryfn:{[f;x]
  / protected execution function, returns success flag and any associated error message if the execution failed
  .[{[f;x](1b;f . x)}[f];enlist x;{(0b;x)}]
 };

extract:{[t;tname;dt;o]
  / main data extract function
  / takes a kdb+ table of data, its name, the date and any option overrides and saves down to parquet format
  .z.m.loginfo[`pqx;"Extracting ",string[tname]," data for ",string dt];
  / override default opts with o where applicable
  opts:default,o;

  / check for count in tables, error out if not
  if[not count[t];
    .z.m.logerr[`pqx;err:"di.pqx: cannot extract from empty table"];
    'err
  ];

  / check for instrument and time cols, error out if not
  if[not opts[`symcol] in cols[t];
    .z.m.logerr[`pqx;err:"di.pqx: no symcol found in table"];
    'err
  ];

  if[not opts[`timecol] in cols[t];
    .z.m.logerr[`pqx;err:"di.pqx: no timecol found in table"];
    'err
  ];

  / if presort, sort by sym then time
  / apply parted attribute on symcol
  if[opts`presort;
    .z.m.loginfo[`pqx;"Sorting data"];
    t:opts[`symcol`timecol] xasc t;
    t:![t;();0b;(enlist opts[`symcol])!enlist(#;enlist `p;opts[`symcol])]
  ];

  writeopt:`PARQUET_VERSION`COMPRESSION!(`V2.LATEST;upper[opts`codec]);

  / build dir locations - done before estimate/calibrate, as calibration's trial write lands under outdir
  if[not count key hsym `$writedir:1_string[opts[`outdir]],string[tname],"/date=",string[dt],"/";
    system "mkdir -p ", writedir;
  ];

  / get symstats and new compression ratio
  .z.m.loginfo[`pqx;"Estimating storage requirements for on-disk tables"];
  statsest:.z.m.estimate[t;opts;writeopt];
  symstats:statsest 0;
  opts[`compressionratio]:statsest 1;
  .z.m.loginfo[`pqx;"Storage estimates calculated"];

  / use symstats to find oversized instruments
  maxsize:opts[`targetsize] * opts[`maxfactor];
  .z.m.loginfo[`pqx;"Creating plans for ",string[tname],"; Date - ",string dt];
  plans:.z.m.plan[symstats;opts;maxsize];

  / check parallel flag to pick iterator function
  parallelfn:(each;peach)[opts[`parallel]];

  .z.m.loginfo[`pqx;"Writing down ",string[tname]," Parquet files to disk for ",string dt];
  res:raze parallelfn [.z.m.writefile[t;opts;writeopt;writedir]; plans];
  .Q.gc[];

  manifest,:res
 };

getdefault:{[]
  / return the current default options dict
  :default;
 };

getmanifest:{[]
  / return the manifest accumulated so far across all extract calls
  :manifest;
 };

init:{[deps]
  / wire the injected logger (required, no fallback). deps: a `log
  / key holding a binary `info`warn`error dict of {[c;m]} loggers (di.log or hand-rolled; a monadic
  / kx.log instance must be wrapped first). e.g. di.pqx.init[enlist[`log]!enlist logdep]
  if[99h<>type deps;
    '"di.pqx: deps must be a dict with a `log key"];
  if[not `log in key deps;
    '"di.pqx: log dependency is required; pass `info`warn`error functions keyed on `log"];
  if[99h<>type deps`log;
    '"di.pqx: log value must be a dict of `info`warn`error functions"];
  if[not all (`info`warn`error) in key deps`log;
    '"di.pqx: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  .z.m.loginfo:deps[`log]`info;
  .z.m.logwarn:deps[`log]`warn;
  .z.m.logerr:deps[`log]`error;
 };