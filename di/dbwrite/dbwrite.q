/ dbwrite - sort, attribute application, save-down manipulation, and GC utilities for on-disk data
/ used by processes that persist data to disk (rdb, wdb, tickerlogreplay)

/ attributes that may legitimately appear in a config (empty leaves a column unattributed)
validatts:``p`s`g`u;

/ built-in fallback config - sort every table by time ascending when no config is supplied
defaultparams:([] tabname:enlist`default; att:enlist`; column:enlist`time; sort:enlist 1b);

init:{[config;deps]
  / wire injected deps and optional module config
  / config: dict with optional `savedownmanipulation (tabname!unary fn applied pre-write)
  / deps: `log!(logdict) where logdict is `info`warn`error!(infofn;warnfn;errfn) - required
  if[99h<>type deps;
    '"di.dbwrite: deps must be a dict with a `log key; see di.log for a default logger"];
  if[not `log in key deps;
    '"di.dbwrite: log dependency is required; pass `info`warn`error functions keyed on `log"];
  if[99h<>type deps`log;
    '"di.dbwrite: log value must be a dict of `info`warn`error functions"];
  if[not all (`info`warn`error) in key deps`log;
    '"di.dbwrite: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  .z.m.log:deps`log;
  .z.m.savedownmanipulation:()!();
  if[99h=type config;
    if[`savedownmanipulation in key config;
      .z.m.savedownmanipulation:config`savedownmanipulation]];
  };

readcsv:{[file]
  / read a sort-config csv and return it as a table (does not store it); pass the result to sort
  / the csv must have the columns tabname,att,column,sort (in any order)
  if[not -11h=type file;
    '"di.dbwrite: readcsv file must be a symbol, got type ",string type file];
  file:hsym file;
  t:parsecsv @[readfile; file; readerr[file]];
  .z.m.log[`info][`dbwrite;"read ",(string count t)," sort config row(s) from ",string file];
  :t;
  };

/ internal - protected file read; only the i/o so a genuine read failure gets the readerr message
readfile:{[file]
  / returns the raw csv lines; header validation and parsing happen in parsecsv
  .z.m.log[`info][`dbwrite;"reading sort config from ",string file];
  :read0 file;
  };

/ internal - log and rethrow a csv read failure
readerr:{[file;e]
  / build the message once, surface it under the dbwrite context, then rethrow it to the caller
  m:"failed to read ",string[file],": ",e;
  .z.m.log[`error][`dbwrite;m];
  'm;
  };

/ internal - validate the header and parse csv lines into a config table
parsecsv:{[lines]
  / map types by column name so the csv column order does not matter; reject any other shape
  / outside the readfile i/o trap so a bad header surfaces as a clear di.dbwrite: error
  if[0=count lines;
    '"di.dbwrite: csv has no header row"];
  hdr:`$"," vs first lines;
  if[not (asc distinct hdr)~`att`column`sort`tabname;
    '"di.dbwrite: csv header must be exactly tabname,att,column,sort; got: ",", " sv string hdr];
  types:{$[x=`sort;"B";"S"]} each hdr;
  :`tabname`att`column`sort#(types;enlist",") 0: lines;
  };

/ internal - validate a sort-config table, signalling a clear error if it is malformed
checkconfig:{[t]
  / guards every sort call so a hand-built or csv-derived table is rejected early if wrong
  if[98h<>type t;
    '"di.dbwrite: config must be a table with columns `tabname`att`column`sort"];
  c:cols t;
  badcols:c where not c in `tabname`att`column`sort;
  if[count badcols;
    '"di.dbwrite: unrecognised config column(s): ",", " sv string badcols];
  missingcols:(`tabname`att`column`sort) where not (`tabname`att`column`sort) in c;
  if[count missingcols;
    '"di.dbwrite: missing required config column(s): ",", " sv string missingcols];
  if[not 1h=type t`sort;
    '"di.dbwrite: the sort column must be boolean"];
  badatts:at where not (at:distinct t`att) in validatts;
  if[count badatts;
    '"di.dbwrite: unrecognised attribute(s) in att column: ",", " sv string badatts];
  };

sort:{[config;tabname;dirs]
  / sort and apply attributes to the on-disk partition dirs for one table using config
  / config: a sort-config table (build it directly or via readcsv); (::) uses the default config
  / tabname: symbol table name; dirs: hsym or list of hsyms (partition directories)
  config:$[(::)~config; defaultparams; config];
  checkconfig config;
  if[not -11h=type tabname;
    '"di.dbwrite: tabname must be a symbol, got type ",string type tabname];
  st:string tabname;
  .z.m.log[`info][`dbwrite;"sorting the ",st," table"];
  sp:getsortparams[config;tabname;st];
  if[not count sp; :()];
  sortdir[sp] each distinct (),dirs;
  .z.m.log[`info][`dbwrite;"finished sorting the ",st," table"];
  };

/ internal - log a sort message then return the resolved rows
logreturn:{[lvl;msg;rows]
  / keeps each branch body in getsortparams to a single statement
  .z.m.log[lvl][`dbwrite;msg];
  :rows;
  };

/ internal - resolve which config rows apply to a table
getsortparams:{[config;tab;st]
  / tab is the table-name symbol (NOT a table); named to avoid clashing with the tabname column
  / a table uses its own rows; unlisted tables fall back to the default row, else are skipped
  if[count tabsp:select from config where tabname=tab;
    :logreturn[`info;"sort params found for: ",st;tabsp]];
  if[count defsp:select from config where tabname=`default;
    :logreturn[`info;"no sort params for: ",st,"; using defaults";defsp]];
  :logreturn[`warn;"no sort params for: ",st,"; skipping sort";0#config];
  };

/ internal - log a sort failure without rethrowing so remaining partitions still run
sorterr:{[sc;dl;e]
  / a single partition failure should not halt the whole run
  .z.m.log[`error][`dbwrite;"failed to sort ",string[dl]," by ",(", " sv string sc),": ",e];
  :();
  };

/ internal - sort one partition directory by the given columns
sortcolumns:{[dloc;sortcols]
  / split out of sortdir so the conditional body there stays a single statement
  .z.m.log[`info][`dbwrite;"sorting ",string[dloc]," by: ",", " sv string sortcols];
  .[xasc;(sortcols;dloc);
    sorterr[sortcols;dloc]];
  };

/ internal - sort columns and apply attributes for a single on-disk partition directory
sortdir:{[sp;dloc]
  / sort by the columns flagged sort=1b, then attribute the columns that request one
  sortcols:exec column from sp where sort, not null column;
  if[count sortcols; sortcolumns[dloc;sortcols]];
  attrcols:select column,att from sp where att in `p`s`g`u;
  if[count attrcols; applyattr[dloc;;]'[attrcols`column;attrcols`att]];
  };

/ internal - log an attribute application failure without rethrowing
attrerr:{[dl;cn;at;e]
  / logs failure and continues so other columns and partitions still get processed
  .z.m.log[`error][`dbwrite;"unable to apply ",string[at]," attr to ",string[cn]," in ",string[dl],": ",e];
  :();
  };

applyattr:{[dloc;colname;att]
  / apply a single kdb+ attribute to an on-disk column; logs and swallows errors so a run continues
  / skip anything that is not a real attribute - covers the empty none-sentinel and any bad value
  if[not att in `p`s`g`u; :()];
  .z.m.log[`info][`dbwrite;"applying ",string[att]," attr to ",string[colname]," in ",string dloc];
  .[{@[x;y;z#]};
    (dloc;colname;att);
    attrerr[dloc;colname;att]];
  };

savedown:{[config;dir;part;tabname;data]
  / write an in-memory table to a date-partitioned hdb partition, then sort it per config
  / config: a sort-config table, or (::) for the built-in default; dir: hdb root (hsym)
  / part: partition value (date/month/int); tabname: symbol; data: in-memory table
  / enumerates syms against the hdb sym file and applies p# to sym before writing
  .z.m.log[`info][`dbwrite;"saving ",string[tabname]," partition ",string[part]," to ",string dir];
  path:` sv (.Q.par[dir;part;tabname];`);
  data:.Q.en[dir;data];
  path set $[`sym in cols data; @[data;`sym;{`p#x}]; data];
  sort[config;tabname;path];
  .z.m.log[`info][`dbwrite;"finished saving ",string tabname];
  };

appenddown:{[dir;part;tabname;data]
  / append rows to an existing on-disk partition (enumerates syms); does not sort
  / call sort separately once the partition is complete, to avoid re-sorting on every append
  / dir: hdb root (hsym); part: partition value; tabname: symbol; data: in-memory table
  .z.m.log[`info][`dbwrite;"appending ",string[tabname]," partition ",string[part]," in ",string dir];
  path:` sv (.Q.par[dir;part;tabname];`);
  if[not count @[key;path;{`$()}];
    '"di.dbwrite: appenddown partition does not exist at ",string path];
  .[path;();,;.Q.en[dir;data]];
  .z.m.log[`info][`dbwrite;"finished appending ",string tabname];
  };

manipulate:{[t;x]
  / apply registered pre-write manipulation to table x of type t; unchanged if none registered
  if[not t in key .z.m.savedownmanipulation; :x];
  :@[.z.m.savedownmanipulation[t]; x; maniperr[x]];
  };

/ internal - log a failed save-down manipulation and fall back to the unmodified table
maniperr:{[x;e]
  / called as the manipulate error handler; the unmodified table is the safe fallback
  .z.m.log[`error][`dbwrite;"save-down manipulation failed: ",e];
  :x;
  };

/ post-EOD hook - called after all tables written and sorted; override at the call site
postreplay:{[d;p]};

/ internal - render a memory-usage dict as a "key=val MB; ..." string
fmtmem:{[m]
  / m: dict of MB values keyed by .Q.w field name
  :"; " sv "=" sv' flip (string key m; (string value m),\:" MB");
  };

/ format current process memory stats as a loggable string
memstats:{[]
  / convert .Q.w[] (bytes) to MB and render it via fmtmem
  :"mem stats: ",fmtmem `long$.Q.w[]%1048576;
  };

gc:{[]
  / run .Q.gc[] and log before/after memory stats
  .z.m.log[`info][`dbwrite;"starting garbage collect. ",memstats[]];
  r:.Q.gc[];
  .z.m.log[`info][`dbwrite;"garbage collection returned ",(string `long$r%1048576),"MB. ",memstats[]];
  };
