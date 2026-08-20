/ merge module for kdb-x
/ on-disk data-merging utilities for the write-down (wdb) flow: intraday data is
/ written to disk in temporary partition segments, then merged into the final hdb
/ partition - either whole-partition, column-by-column, or a hybrid of the two chosen
/ per partition by a row-count / byte-size limit
/ merging keeps memory flat - segments are read and upserted a batch at a time rather
/ than held in memory and written once at end-of-day
/ the parted (`p#) column(s) for a table are supplied by the caller as extrapartitiontype;
/ the module never reads sort config itself, so it stays independent of di.sort
/ config and the injected log dependency are passed to init in a single dictionary: config
/ keys (see merge.md) are optional with defaults; log is required and init errors
/ immediately if it is missing or does not provide info/error - see merge.md
/ module-local state convention: mutable state and injected deps are held under .z.m and
/ accessed via .z.m at every call site; nothing is read bare

/ ============================================================
/ module state and defaults
/ ============================================================

/ schema template for the partition-size tracking table - the live copy is held in
/ .z.m.partsizes, seeded fresh by init and reset by clearpartsizes
partsizesschema:([ptdir:`symbol$()] rowcount:`long$(); bytes:`long$());

/ configuration defaults - overridden by the config keys in the dict passed to init
mergebybytelimitdefault:0b;   / 0b = size batches / choose method by row count, 1b = by byte-size estimate
partlimitdefault:1000;        / maximum number of partitions merged together in a single batch

/ ============================================================
/ init guard
/ ============================================================

initialised:{[]
  / has init run? .z.m.loginfo has no load-time default - only init ever sets it - so this
  / probe can't be fooled by a same-named constant, unlike partsizes/mergebybytelimit/partlimit
  / which all start with real, valid-looking defaults whether init has run or not
  :@[{.z.m.loginfo;1b};::;{[e] :0b}];
  };

requireinit:{[ctx]
  / every exported function except init/getapimeta refuses to run before init has wired the
  / deps - without this a pre-init call would fail on an unset .z.m.loginfo with a confusing
  / raw error instead of a clear one
  if[not initialised[];
    '"di.merge: ",string[ctx],": init must be called before any other function"];
  };

/ ============================================================
/ internal helpers
/ ============================================================

/ merge a single column from a segment into the destination partition, logging on failure
mergeonecol:{[dest;segment;col]
  / filepaths to the destination column and the matching column in the segment
  destcol:` sv dest,col;
  destdata:get segcol:` sv segment,col;
  .z.m.loginfo[`merge;"merging ",(string segcol)," to ",string destcol];
  .[upsert;(destcol;destdata);
    {[dc;e] .z.m.logerr[`merge;"failed to save data to ",(string dc)," with error : ",e]}[destcol;]];
  };

/ ============================================================
/ public api - partition-size tracking
/ ============================================================

/ accumulate the row count and byte-size estimate for a freshly-written segment
trackpartition:{[ptdir;rowcount;bytes]
  / call each time data is written to a segment; keyed by partition directory
  requireinit[`trackpartition];
  .z.m.partsizes[ptdir]+:(rowcount;bytes);
  };

/ drop all tracked segment sizes - call once end-of-day merging is complete
clearpartsizes:{[]
  requireinit[`clearpartsizes];
  .z.m.partsizes:0#partsizesschema;
  };

/ current tracked segment sizes (e.g. to sync to sort-worker processes)
getpartsizes:{[]
  requireinit[`getpartsizes];
  .z.m.partsizes
  };

/ upsert a partsizes-shaped table received from a peer process into local tracked state
syncpartsizes:{[t]
  / t: a table shaped like getpartsizes[] (ptdir/rowcount/bytes), typically received over IPC
  / from a peer process's own getpartsizes[] call - upserts wholesale into local state, giving
  / the receive side of the legacy raw-IPC partsizes fan-out a real function to go through
  requireinit[`syncpartsizes];
  .z.m.partsizes:.z.m.partsizes upsert t;
  };

/ ============================================================
/ public api - merging
/ ============================================================

/ split the partition directories into batches to be merged together
getpartchunks:{[partdirs;mergelimit]
  / each batch stays within mergelimit (row count or byte estimate per mergebybytelimit) and
  / holds no more than partlimit partitions
  requireinit[`getpartchunks];
  / tracked sizes for just the partitions we are merging
  t:select from .z.m.partsizes where ptdir in partdirs;
  / the measure we accumulate against the limit
  r:$[.z.m.mergebybytelimit;exec bytes from t;exec rowcount from t];
  / running-total scan resets to the current partition whenever adding it would breach the limit
  l:(where r={$[z<x+y;y;x+y]}\[0;r;mergelimit]),(select count i from t)[`x];
  / where a batch spans more than partlimit partitions, split it into partlimit-sized pieces
  s:-1_distinct asc raze {$[(x[y]-x[y-1])<=.z.m.partlimit;x[y];
    x[y],first each .z.m.partlimit cut x[y-1]+til x[y]-x[y-1]]}/:[l;til count l];
  / cut the partition-directory list at the computed batch boundaries
  s cut exec ptdir from t
  };

/ merge one batch of whole partition segments into the destination partition
mergebypart:{[extrapartitiontype;dest;partchunks]
  / re-sorts the batch by the parted column(s) first if the p# attribute cannot otherwise be applied
  requireinit[`mergebypart];
  .z.m.loginfo[`merge;"reading partition/partitions ",", " sv string partchunks];
  chunks:get each partchunks;
  / a single segment reads back as a table; multiple read back as a list of tables to join
  if[98<>type chunks;chunks:(,/)chunks];
  .z.m.loginfo[`resort;"checking that the contents of this subpartition conform"];
  / can the p# attribute be applied as-is? if not, the data must be re-sorted by the parted column
  pattrtest:@[{@[x;y;`p#];0b}[chunks;];extrapartitiontype;{1b}];
  if[pattrtest;
    .z.m.loginfo[`resort;"re-sorting contents of subpartition"];
    chunks:xasc[extrapartitiontype;chunks];
    .z.m.loginfo[`resort;"the p attribute can now be applied"];
    ];
  .z.m.loginfo[`merge;"upserting ",(string count chunks)," rows to ",string dest];
  / append the merged rows to permanent storage, logging (not throwing) on failure
  / e arrives already a string from the protected-apply mechanism - do not re-stringify it: string
  / of an already-string value maps over each char individually, corrupting the message and making
  / this handler itself throw, which defeats the log-not-throw contract this line exists to provide
  .[upsert;(dest;chunks);
    {[e;d;p] .z.m.logerr[`merge;"failed to merge to ",string[d]," from segments ",(", " sv string p)," Error is - ",e]}[;dest;partchunks]];
  };

/ merge one segment into the destination partition a column at a time
mergebycol:{[tableinfo;dest;segment]
  / holds at most a single column in memory rather than the whole partition
  requireinit[`mergebycol];
  .z.m.loginfo[`merge;"upserting columns from ",(string segment)," to ",string dest];
  mergeonecol[dest;segment;] each cols tableinfo[1];
  };

/ merge the given partitions using whichever method fits each one
mergehybrid:{[extrapartitiontype;tableinfo;dest;partdirs;mergelimit]
  / whole-partition for those within the limit, column-by-column for any single partition over it
  requireinit[`mergehybrid];
  overlimit:$[.z.m.mergebybytelimit;
    exec ptdir from .z.m.partsizes where ptdir in partdirs,bytes>mergelimit;
    exec ptdir from .z.m.partsizes where ptdir in partdirs,rowcount>mergelimit];
  if[(count overlimit)<>count partdirs;
    partdirs:partdirs except overlimit;
    .z.m.loginfo[`merge;"merging ",(", " sv string partdirs)," by whole partition"];
    mergebypart[extrapartitiontype;` sv dest,`]'[getpartchunks[partdirs;mergelimit]];
    ];
  if[0<>count overlimit;
    .z.m.loginfo[`merge;"merging ",(", " sv string overlimit)," column by column"];
    mergebycol[tableinfo;dest]'[overlimit];
    / column-by-column merge writes no .d file - create one if none exists yet
    if[()~key ` sv dest,`.d;
      .z.m.loginfo[`merge;"creating file ",string ` sv dest,`.d];
      (` sv dest,`.d) set cols tableinfo[1];
      ];
    ];
  };

/ ============================================================
/ public api - parted-column checks and partition enumeration
/ ============================================================

/ error-log any parted column named for the table that is absent from it
checkpartitiontype:{[tablename;extrapartitiontype]
  requireinit[`checkpartitiontype];
  $[count colsnotintab:extrapartitiontype where not extrapartitiontype in cols get tablename;
    .z.m.logerr[`checkpart;"parted columns ",(", " sv string colsnotintab),
      " not present in the parted columns supplied for ",(string tablename)," table"];
    .z.m.loginfo[`checkpart;"all parted columns supplied are present in ",(string tablename)," table"]];
  };

/ confirm every parted column has an enumerable type (h/i/j/s) so it can key a partition
checkenumerabletype:{[tablename;extrapartitiontype]
  requireinit[`checkenumerabletype];
  $[all extrapartitiontype in exec c from meta[tablename] where t in "hijs";
    .z.m.loginfo[`checkenumerable;"all columns do have an enumerable type in ",(string tablename)," table"];
    .z.m.logerr[`checkenumerable;"not all columns ",string[extrapartitiontype],
      " do have an enumerable type in ",(string tablename)," table"]];
  };

/ distinct combinations of the parted column values - one per partition directory
getextrapartitions:{[tablename;extrapartitiontype]
  / functional form of: select distinct extrapartitiontype from tablename
  requireinit[`getextrapartitions];
  value each ?[tablename;();1b;extrapartitiontype!extrapartitiontype]
  };

/ partition values grouped by the first character of the (single) parted column
getfirstcharpartitions:{[tablename;extrapartitiontype]
  requireinit[`getfirstcharpartitions];
  raze each value (?[tablename;();();(distinct;first extrapartitiontype)])
    group ?[tablename;();();({first each string x};(distinct;first extrapartitiontype))]
  };

/ ============================================================
/ initialisation
/ ============================================================

init:{[deps]
  / deps: dict - required `log (info, error only - merge.q never calls warn, confirmed
  /              function-by-function against the legacy source);
  /              optional `mergebybytelimit (default 0b), `partlimit (default 1000)
  / example: merge.init[enlist[`log]!enlist logdep]
  if[99h<>type deps;
    '"di.merge: deps must be a dict with `log key"];
  if[not `log in key deps;
    '"di.merge: log dependency is required; pass `info`error functions - see di.log"];
  if[99h<>type deps`log;
    '"di.merge: log value must be a dict; pass `info`error functions"];
  if[not all `info`error in key deps`log;
    '"di.merge: log dict must have `info`error keys; got: ",(", " sv string key deps`log)];
  .z.m.loginfo:(deps`log)`info;
  .z.m.logerr:(deps`log)`error;
  .z.m.mergebybytelimit:$[`mergebybytelimit in key deps;deps`mergebybytelimit;mergebybytelimitdefault];
  .z.m.partlimit:$[`partlimit in key deps;deps`partlimit;partlimitdefault];
  / preserve any partitions already tracked across a re-init (e.g. a live config reload) - partsizes
  / is independent of the log/mergebybytelimit/partlimit deps a re-init is typically changing, and
  / silently wiping tracked-but-unmerged segment sizes is a worse failure mode than leaving them be
  priorpartsizes:@[{.z.m.partsizes};::;{[e] 0#partsizesschema}];
  .z.m.partsizes:priorpartsizes;
  .z.m.loginfo[`merge;$[0<count priorpartsizes;
    "di.merge initialised, ",(string count priorpartsizes)," segment(s) already tracked, preserved";
    "di.merge initialised"]];
  };

/ ============================================================
/ api metadata
/ ============================================================

getapimeta:{[]
  / this module's api metadata, one row per callable api function, for di.torq to register with
  / di.api. init/getapimeta are plumbing di.torq calls by convention and are not registered.
  / names are bare - di.torq applies the process-wide qualification
  :flip `name`public`descrip`params`return!flip(
    (`checkpartitiontype;
      1b;"log any parted column supplied that is not a column on the table";
      "[symbol: tablename; symbol list: extrapartitiontype]";"null");
    (`checkenumerabletype;
      1b;"log whether every parted column has an enumerable type (h/i/j/s)";
      "[symbol: tablename; symbol list: extrapartitiontype]";"null");
    (`getextrapartitions;
      1b;"distinct combinations of the parted column values, one per partition";
      "[symbol: tablename; symbol list: extrapartitiontype]";"list: value vectors, one per partition");
    (`getfirstcharpartitions;
      1b;"partition values grouped by first character of the parted column";
      "[symbol: tablename; symbol list: extrapartitiontype]";"list: grouped values");
    (`getpartchunks;
      1b;"split partition directories into row/byte-limited, partlimit-capped batches";
      "[symbol list: partdirs; long: mergelimit]";"list: batches of partition directories");
    (`mergebypart;
      1b;"merge a batch of whole partition segments into the destination partition";
      "[symbol list: extrapartitiontype; hsym: dest; symbol list: partchunks]";"null");
    (`mergebycol;
      1b;"merge one segment into the destination partition a column at a time";
      "[list: tableinfo (tablename;schema); hsym: dest; hsym: segment]";"null");
    (`mergehybrid;
      1b;"merge partitions whole or column-by-column, chosen per partition by size";
      "[symbol list: extrapartitiontype; list: tableinfo; hsym: dest; symbol list: partdirs; long: mergelimit]";
      "null");
    (`trackpartition;
      1b;"accumulate row count and byte-size estimate for a freshly-written segment";
      "[symbol: ptdir; long: rowcount; long: bytes]";"null");
    (`clearpartsizes;1b;"drop all tracked segment sizes";"[]";"null");
    (`getpartsizes;  1b;"current tracked segment sizes";"[]";"table: ptdir/rowcount/bytes");
    (`syncpartsizes;
      1b;"upsert a partsizes table received from a peer process into local tracked state";
      "[table: t]";"null");
    (`version;1b;"module version string, read from the VERSION file";"[]";"string: semver, e.g. 0.1.0"));
  };
