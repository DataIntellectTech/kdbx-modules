/ merge module for kdb-x
/ on-disk data-merging utilities for the write-down (wdb) flow: intraday data is
/ written to disk in temporary partition segments, then merged into the final hdb
/ partition - either whole-partition, column-by-column, or a hybrid of the two chosen
/ per partition by a row-count / byte-size limit
/ merging keeps memory flat - segments are read and upserted a batch at a time rather
/ than held in memory and written once at end-of-day
/ the parted (`p#) column(s) for a table are supplied by the caller as extrapartitiontype;
/ the module never reads sort config itself, so it stays independent of di.sort
/ config and dependencies are passed to init in a single dictionary: config keys (see
/ merge.md) are optional with defaults; log is required and init errors immediately if it
/ is missing - see merge.md
/ module-local state convention: read config bare, mutate via .z.m, and access injected
/ dependencies via .z.m at every call site

/ ============================================================
/ module state and defaults
/ ============================================================

/ row count and byte-size estimate of each on-disk segment as it is written, keyed by
/ partition directory - drives the batch sizing and merge-method decisions below
partsizes:([ptdir:`symbol$()] rowcount:`long$(); bytes:`long$());

/ configuration defaults - overridden by the config dictionary passed to init
mergebybytelimit:0b;   / 0b = size batches / choose method by row count, 1b = by byte-size estimate
partlimit:1000;        / maximum number of partitions merged together in a single batch

/ ============================================================
/ internal helpers
/ ============================================================

/ normalise an injected logger to the binary {[c;m]} contract
normlog:{[logdict]
  / detect a kx.log instance by its marker keys and wrap its monadic level functions into
  / binary {[c;m]}, folding the context tag into the message; a plain {[c;m]} dict passes through
  $[any `getlvl`sinks`fmts in key logdict;
    `info`warn`error!(
      {[fn;c;m] fn[string[c],": ",m]}[logdict`info;];
      {[fn;c;m] fn[string[c],": ",m]}[logdict`warn;];
      {[fn;c;m] fn[string[c],": ",m]}[logdict`error;]);
    logdict]
  };

/ validate and wire the injected dependencies from the deps dict
setdeps:{[deps]
  / log is the only dependency - required, and must provide info/warn/error (a kx.log
  / instance is auto-wrapped by normlog); validate before writing any module state
  if[99h<>type deps;
    '"di.merge: deps must be a dictionary of config and injected dependencies - see merge.md"];
  if[not `log in key deps;
    '"di.merge: log dependency is required; pass `info`warn`error (or a kx.log logger) keyed on `log"];
  if[99h<>type deps`log;
    '"di.merge: log must be a dict of info/warn/error functions (or a kx.log logger)"];
  lg:normlog deps`log;
  if[not all `info`warn`error in key lg;
    '"di.merge: log must provide info/warn/error; got: ",", " sv string key lg];
  .z.m.log:lg;
  };

/ apply recognised config overrides from the deps dict, defaulting where a key is absent
setconfig:{[deps]
  cfg:$[99h=type deps;deps;()!()];
  .z.m.mergebybytelimit:$[`mergebybytelimit in key cfg;cfg`mergebybytelimit;0b];
  .z.m.partlimit:$[`partlimit in key cfg;cfg`partlimit;1000];
  };

/ merge a single column from a segment into the destination partition, logging on failure
mergeonecol:{[dest;segment;col]
  / filepaths to the destination column and the matching column in the segment
  destcol:` sv dest,col;
  destdata:get segcol:` sv segment,col;
  .z.m.log[`info][`merge;"merging ",(string segcol)," to ",string destcol];
  .[upsert;(destcol;destdata);
    {[dc;e] .z.m.log[`error][`merge;"failed to save data to ",(string dc)," with error : ",e]}[destcol;]];
  };

/ ============================================================
/ public api - partition-size tracking
/ ============================================================

/ accumulate the row count and byte-size estimate for a freshly-written segment
trackpartition:{[ptdir;rowcount;bytes]
  / call each time data is written to a segment; keyed by partition directory
  .z.m.partsizes[ptdir]+:(rowcount;bytes);
  };

/ drop all tracked segment sizes - call once end-of-day merging is complete
clearpartsizes:{
  .z.m.partsizes:0#partsizes;
  };

getpartsizes:{partsizes};   / current tracked segment sizes (e.g. to sync to sort-worker processes)

/ ============================================================
/ public api - merging
/ ============================================================

/ split the partition directories into batches to be merged together
getpartchunks:{[partdirs;mergelimit]
  / each batch stays within mergelimit (row count or byte estimate per mergebybytelimit) and
  / holds no more than partlimit partitions
  / tracked sizes for just the partitions we are merging
  t:select from partsizes where ptdir in partdirs;
  / the measure we accumulate against the limit
  r:$[mergebybytelimit;exec bytes from t;exec rowcount from t];
  / running-total scan resets to the current partition whenever adding it would breach the limit
  l:(where r={$[z<x+y;y;x+y]}\[0;r;mergelimit]),(select count i from t)[`x];
  / where a batch spans more than partlimit partitions, split it into partlimit-sized pieces
  s:-1_distinct asc raze {$[(x[y]-x[y-1])<=partlimit;x[y];x[y],first each partlimit cut x[y-1]+til x[y]-x[y-1]]}/:[l;til count l];
  / cut the partition-directory list at the computed batch boundaries
  s cut exec ptdir from t
  };

/ merge one batch of whole partition segments into the destination partition
mergebypart:{[extrapartitiontype;dest;partchunks]
  / re-sorts the batch by the parted column(s) first if the p# attribute cannot otherwise be applied
  .z.m.log[`info][`merge;"reading partition/partitions ",", " sv string partchunks];
  chunks:get each partchunks;
  / a single segment reads back as a table; multiple read back as a list of tables to join
  if[98<>type chunks;chunks:(,/)chunks];
  .z.m.log[`info][`resort;"checking that the contents of this subpartition conform"];
  / can the p# attribute be applied as-is? if not, the data must be re-sorted by the parted column
  pattrtest:@[{@[x;y;`p#];0b}[chunks;];extrapartitiontype;{1b}];
  if[pattrtest;
    .z.m.log[`info][`resort;"re-sorting contents of subpartition"];
    chunks:xasc[extrapartitiontype;chunks];
    .z.m.log[`info][`resort;"the p attribute can now be applied"];
    ];
  .z.m.log[`info][`merge;"upserting ",(string count chunks)," rows to ",string dest];
  / append the merged rows to permanent storage, logging (not throwing) on failure
  .[upsert;(dest;chunks);
    {[e;d;p] .z.m.log[`error][`merge;"failed to merge to ",string[d]," from segments ",(", " sv string p)," Error is - ",string e]}[;dest;partchunks]];
  };

/ merge one segment into the destination partition a column at a time
mergebycol:{[tableinfo;dest;segment]
  / holds at most a single column in memory rather than the whole partition
  .z.m.log[`info][`merge;"upserting columns from ",(string segment)," to ",string dest];
  mergeonecol[dest;segment;] each cols tableinfo[1];
  };

/ merge the given partitions using whichever method fits each one
mergehybrid:{[extrapartitiontype;tableinfo;dest;partdirs;mergelimit]
  / whole-partition for those within the limit, column-by-column for any single partition over it
  overlimit:$[mergebybytelimit;
    exec ptdir from partsizes where ptdir in partdirs,bytes>mergelimit;
    exec ptdir from partsizes where ptdir in partdirs,rowcount>mergelimit];
  if[(count overlimit)<>count partdirs;
    partdirs:partdirs except overlimit;
    .z.m.log[`info][`merge;"merging ",(", " sv string partdirs)," by whole partition"];
    mergebypart[extrapartitiontype;` sv dest,`]'[getpartchunks[partdirs;mergelimit]];
    ];
  if[0<>count overlimit;
    .z.m.log[`info][`merge;"merging ",(", " sv string overlimit)," column by column"];
    mergebycol[tableinfo;dest]'[overlimit];
    / column-by-column merge writes no .d file - create one if none exists yet
    if[()~key ` sv dest,`.d;
      .z.m.log[`info][`merge;"creating file ",string ` sv dest,`.d];
      (` sv dest,`.d) set cols tableinfo[1];
      ];
    ];
  };

/ ============================================================
/ public api - parted-column checks and partition enumeration
/ ============================================================

/ error-log any parted column named for the table that is absent from it
checkpartitiontype:{[tablename;extrapartitiontype]
  $[count colsnotintab:extrapartitiontype where not extrapartitiontype in cols get tablename;
    .z.m.log[`error][`checkpart;"parted columns ",(", " sv string colsnotintab)," are defined in sort.csv but not present in ",(string tablename)," table"];
    .z.m.log[`info][`checkpart;"all parted columns defined in sort.csv are present in ",(string tablename)," table"]];
  };

/ confirm every parted column has an enumerable type (h/i/j/s) so it can key a partition
checkenumerabletype:{[tablename;extrapartitiontype]
  $[all extrapartitiontype in exec c from meta[tablename] where t in "hijs";
    .z.m.log[`info][`checkenumerable;"all columns do have an enumerable type in ",(string tablename)," table"];
    .z.m.log[`error][`checkenumerable;"not all columns ",string[extrapartitiontype]," do have an enumerable type in ",(string tablename)," table"]];
  };

/ distinct combinations of the parted column values - one per partition directory
getextrapartitions:{[tablename;extrapartitiontype]
  / functional form of: select distinct extrapartitiontype from tablename
  value each ?[tablename;();1b;extrapartitiontype!extrapartitiontype]
  };

/ partition values grouped by the first character of the (single) parted column
getfirstcharpartitions:{[tablename;extrapartitiontype]
  raze each value (?[tablename;();();(distinct;first extrapartitiontype)]) group ?[tablename;();();({first each string x};(distinct;first extrapartitiontype))]
  };

/ ============================================================
/ initialisation
/ ============================================================

init:{[deps]
  / initialise from a single dictionary holding config overrides and the injected log dependency
  / config keys are optional and fall back to defaults:
  /   `mergebybytelimit - 0b (row count) or 1b (byte-size estimate)   - default 0b
  /   `partlimit        - max partitions merged together in a batch   - default 1000
  / dependency is required:
  /   `log - a logger providing info/warn/error (a kx.log instance is auto-wrapped)
  / example:
  /   merge.init[enlist[`log]!enlist kxlog]
  setdeps deps;
  setconfig deps;
  .z.m.log[`info][`merge;"di.merge initialised"];
  };
