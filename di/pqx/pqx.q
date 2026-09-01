/ define default config
default:(
  `targetsize`maxfactor`splitoversized`calibrate`onesymperfile`compressionratio,
  `symcol`timecol`presort`rowgroupbytes`codec`complevel`virtualcols,
  `parallel`outdir`filestub
  )!(
  512*1024*1024;                 / ~512 MB target file size
  1.5;                           / hard cap = target * maxfactor
  1b;                            / split instruments larger than the cap
  1b;                            / run a calibration write to set the ratio
  0b;                            / enforce a single instrument per file
  0.30;                          / raw->parquet ratio if not calibrating
  `sym;                          / instrument column
  `time;                         / time column
  1b;                            / sort by (sym,time) if not already
  128*1024*1024;                 / ~128 MB row groups
  `zstd;                         / codec
  3;                             / compression level
  `symbol$();                    / virtual (path-only) partition columns, taking precedence over onesymperfile/splitoversized
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
  / group by virtualcols as well as symcol, so a sym occurring under multiple virtualcols combinations gets its own row
  gcols:distinct o[`virtualcols],o[`symcol];
  cnts:`rowcnt xasc 0!?[t;();gcols!gcols;enlist[`rowcnt]!enlist(count;o[`timecol])]; / select rowcnt:count time by gcols from t, using appropriate substitutions for time and sym/virtualcols
  medsym:cnts @ first where abs[cnt-med[cnt]]=min[abs[cnt-med[cnt:cnts`rowcnt]]];
  mask:min each flip {[t;medsym;x] t[x]=medsym[x]}[t;medsym] each gcols; / row matches medsym's full (virtualcols,symcol) combination, not just its sym
  bytesperrow:%[-22!t:.z.m.checkandconvertcols t[where mask];medsym`rowcnt];

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
  hdel hsym `$testloc;

  / return new ratio
  .z.m.loginfo[`pqx;"Returning calibrated compression ratio"];
  :newratio
 };

calcsize:{[tbl;symcol;syms;seqno]
  / find the estimated size in bytes for file to be saved down by querying symstats
  .z.m.loginfo[`pqx;"Getting estimated bytes for planned files"];
  :sum[?[tbl;enlist(in;symcol;enlist syms);0b;()]`estbyt]
 };

plan:{[t;o;maxsize]
  / planning function to bucket instruments based on next-fit packing
  / if one sym per file, just output individual buckets for each sym
  / else
  / if an instrument can be added to a bucket without that bucket exceeding the target size, it will be added to that bucket
  / else a new bucket is created
  / large instruments are also split into multiple files if splitoversized flag is true
  symstats:t;

  / virtualcols take precedence over everything else - one file per distinct combination.
  / computed directly here (rather than through the shared bucket-then-recompute tail below) because
  / symstats can carry multiple rows per sym once virtualcols grouping is active (see estimate), and the
  / tail's calcsize call would double count a sym's bytes across its different virtualcols combinations
  if[count o`virtualcols;
    .z.m.loginfo[`pqx;"Enforcing one file per virtualcols combination"];
    grp:0!?[t;();(o`virtualcols)!o`virtualcols;`syms`estbytes!((o`symcol);(sum;`estbyt))];
    :update seqno:enlist each 1+til count grp, estbytes:enlist each "j"$estbytes from grp
  ];

  plans:();

  / if one sym per file, enlist each sym to assign to individual buckets
  / else move to oversized and packing logic
  $[o`onesymperfile;
    [.z.m.loginfo[`pqx;"Enforcing one sym per file"];
    plans,:enlist each t[o[`symcol]]
    ];
    / if split oversized is required, check against maxsize and return a plan entry for each required file
    [if[o`splitoversized;
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
      ]
    ]
  ];
  plans:flip `seqno`syms!((1 + til count plans);plans);

  / attach estbytes by file to plan's output
  :0!`syms xgroup update estbytes:"j"$.z.m.calcsize[symstats;o`symcol;;]'[syms;seqno]%count seqno by syms from plans
 };

datalookup:{[t;symcol;syms;cnt;mask]
  / get lists of indices by file
  / a pass with multiple instruments is assumed to be one file only, hence the return is flattened into one list
  / mask restricts to rows belonging to this file's virtualcols combination (all 1b when virtualcols is unset)
  $[1<count syms;
    :enlist[raze/[.z.m.datalookuponesym[t;symcol;;cnt;mask] each syms]];
    :.z.m.datalookuponesym[t;symcol;first[syms];cnt;mask]
  ]
 };

datalookuponesym:{[t;symcol;sym;cnt;mask]
  / finds indices where instrument occurs in table partition (and matches the virtualcols mask), and cuts into lists if the result set is to be split
  :ceiling [%[count[where mask&t[symcol] in sym];cnt]] cut where mask&t[symcol] in sym
 };

writefile:{[t;o;writeopt;writedir;map]
  / writes data to disk in Parquet format
  / returns stats to be inserted into the manifest
  
  syms:map`syms;

  / if virtualcols are set, this file's combination becomes a Hive-style `col=value` subdirectory under writedir,
  / and rows must be restricted to this combination - the same sym can occur under other combinations too.
  / the subdirectory itself is created up front by extract, on the main thread - writefile runs under peach
  / when parallel is on, and forking via system from a secondary thread is unsafe and throws 'sys
  combo:o[`virtualcols]#map;
  segs:{string[x],"=",string y}'[key combo;value combo];
  writedir:writedir,$[count segs;("/" sv segs),"/";""];
  combomask:$[count segs;min each flip {[t;x;y] t[x]=y}[t]'[key combo;value combo];count[t]#1b];

  map:flip (`syms,o[`virtualcols]) _ map;

  / row indices must be found before virtualcols columns are dropped - datalookup needs t[symcol], and symcol
  / may itself be one of the virtualcols columns. virtualcols values are fixed for the whole file (per combomask
  / above) and encoded in its path already, so t is stripped of them in place afterwards - once here, not
  / duplicated into every row of the on-disk data, and not dropped later from an already row-indexed slice
  / (which breaks the arrow write whenever a file holds more than one instrument). guarded on count: a
  / functional delete of an EMPTY column list against a `p#-attributed symcol (set by presort, on by
  / default) silently returns a zero-row table instead of being the no-op it should be
  idx:.z.m.datalookup[t;o`symcol;syms;count map;combomask];
  t:$[count o`virtualcols;![t;();0b;o`virtualcols];t];

  / build paths for each seqno
  paths:writedir,/:o[`filestub],/:"-",/:("0"^-5$string[map`seqno]),\:".parquet";

  / data to write, iterated by file
  res:raze {[t;o;writeopt;split;syms;map;path;i]
    .z.m.loginfo[`pqx;"Writing seqNo ",string[map`seqno],", path - ",path];
    res:.z.m.tryfn[`.m.di.0pqx.arrow.pq.writeParquetFromTable;(path;.z.m.checkandconvertcols t[i];writeopt)];
    $[first res;
      .z.m.loginfo[`pqx;"seqNo ",string[map`seqno]," write successful"];
      .z.m.logwarn[`pqx;"seqNo ",string[map`seqno]," write unsuccessful. Error - ",last res]
    ];
    :`file`seq`syms`nsyms`rows`mintime`maxtime`estbytes`bytes`split`status!/: flip (
      hsym `$path;
      map`seqno;
      enlist[syms];
      count[syms];
      count[i];
      ?[t[i];();();(min;o`timecol)];
      ?[t[i];();();(max;o`timecol)];
      map`estbytes;
      @[hcount;hsym `$path;0];
      split;
      `error`ok[first res]
    )
  }[t;o;writeopt;1<count map;syms;;;]'[map;paths;idx];

  :res
 };

readfile:{[path;readopt]
  / reads back a single file written by extract, reconstructing any values that were stripped from the
  / on-disk data and encoded only in its path - the date partition and any virtualcols combination (see writefile).
  / virtualcols values are reconstructed as symbols; the date segment is reconstructed as an actual date.
  / path may be an hsym or a plain string, with or without a leading colon
  p:$[-11h=type path;string path;path];
  p:$[":"=first p;1_p;p];
  parts:"/" vs p;
  segs:parts where parts like "*=*";
  ks:`$first each "=" vs/: segs;
  vals:last each "=" vs/: segs;
  vals:{[k;v] $[k=`date;"D"$v;`$v]}'[ks;vals];
  t:.m.di.0pqx.arrow.pq.readParquetToTable[path;readopt];
  / each value is enlisted - a bare symbol atom in a functional update is read as a column reference, not a literal
  :![t;();0b;ks!enlist each vals]
 };

buildvirtualtable:{[hdbdir;tname;datecol;virtualcols]
  / builds a queryable virtual table over parquet files scattered under hdbdir/tname, without reading any
  / of their data - partition values (the date segment and any virtualcols segments) are reconstructed from
  / each file's hive-style path, mirroring how writefile strips those same columns from the on-disk data
  path:` sv hdbdir,tname;
  files:([] file:system"find \"",(1 _ string path),"\" -name \"*.parquet\" | sort");
  files:update split:"/" vs/:file from files;
  lv:1+count where "/"=string path;
  levels:(),datecol,virtualcols;
  levelcols:{[datecol;x] (castvirtualcol[datecol;x;];`split)}[datecol] each lv+til count levels;
  files:![files;();0b;(`file,levels)!enlist[({hsym `$x};`file)],levelcols];
  pqt.mkP (levels#files)!pq.pq each exec file from files
 };

castvirtualcol:{[datecol;x;y]
  / casts the xth hive-style path segment (a "key=value" string) of every row in y's split column to its
  / reconstructed value - a date if it's the datecol level, else a symbol
  :$[datecol = first `$distinct first each "=" vs' v:y[;x];
    "D"$last each "=" vs' v;
    `$last each "=" vs' v
  ]
 };

tryfn:{[f;x]
  / protected execution function, returns success flag and any associated error message if the execution failed
  .[{[f;x](1b;f . x)}[f];enlist x;{(0b;x)}]
 };

extract:{[t;tname;dt;o]
  / main data extract function
  / takes a kdb+ table of data, its name, the date and any option overrides and saves down to parquet format

  / check for bad input keys
  if[any not key[o] in key[default];
    .z.m.logerr[`pqx;err:"di.pqx: input keys not recognised - ", "," sv string key[o] where not key[o] in key default];
    'err 
  ];

  .z.m.loginfo[`pqx;"Extracting table: ",string[tname]," data for date: ",string dt];
  / override default opts with o where applicable
  opts:default,o;

  / if one sym per file requested, turn off splitoversized
  if[o`onesymperfile;
    .z.m.loginfo[`pqx;"onesymperfile requested, turning off splitoversized"];
    opts[`splitoversized]:0b
  ];

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

  / virtualcols take precedence over onesymperfile/splitoversized - one file per combination
  if[count opts[`virtualcols];
    if[not all opts[`virtualcols] in cols[t];
      .z.m.logerr[`pqx;err:"di.pqx: not all virtualcols found in table"];
      'err
    ];
    .z.m.loginfo[`pqx;"virtualcols requested, turning off onesymperfile and splitoversized"];
    opts[`onesymperfile]:0b;
    opts[`splitoversized]:0b;
    if[-11h=type opts`virtualcols;
      opts[`virtualcols]:enlist opts`virtualcols
    ]
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
    system "mkdir -p \"", writedir,"\"";
  ];

  / get symstats and new compression ratio
  .z.m.loginfo[`pqx;"Estimating storage requirements for on-disk tables"];
  statsest:.z.m.estimate[t;opts;writeopt];
  symstats:statsest 0;
  opts[`compressionratio]:statsest 1;
  .z.m.loginfo[`pqx;"Storage estimates calculated"];

  / use symstats to find oversized instruments
  maxsize:opts[`targetsize] * opts[`maxfactor];
  .z.m.loginfo[`pqx;"Creating plans for ",string[tname],"; date: ",string dt];
  plans:.z.m.plan[symstats;opts;maxsize];

  / pre-create every virtualcols combination's output subdirectory here, on the main thread - writefile runs
  / under peach when parallel is on, and forking via system from a secondary thread is unsafe (throws 'sys)
  if[count opts`virtualcols;
    {[writedir;combo]
      d:writedir,("/" sv {string[x],"=",string y}'[key combo;value combo]),"/";
      if[not count key hsym `$d;
        system "mkdir -p \"",d,"\"";
      ]
    }[writedir] each distinct opts[`virtualcols]#plans;
  ];

  / check parallel flag to pick iterator function
  parallelfn:(each;peach)[opts[`parallel]];

  .z.m.loginfo[`pqx;"Writing down ",string[tname]," Parquet files to disk for ",string dt];
  res:raze parallelfn [.z.m.writefile[t;opts;writeopt;writedir]; plans];
  .Q.gc[];

  / write down manifest to partition - best-effort, does not abort the extract call if it fails
  .z.m.loginfo[`pqx;"Writing down manifest file for table: ",string[tname],"; date: ",string dt];
  manwrite:.z.m.tryfn[set;(hsym `$writedir,"manifest";res)];
  if[not first manwrite;
    .z.m.logwarn[`pqx;"di.pqx: error writing manifest to disk: ",last manwrite]
  ];

  / attach to global manifest and return stats for this extract
  manifest,:res;
  :res
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
