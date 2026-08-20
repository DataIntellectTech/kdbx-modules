/ dbwrite - write, sort, and attribute utilities for on-disk data
/ used by processes that persist data to disk (rdb, wdb, tickerlogreplay)

/ attributes that may legitimately appear in a config (empty leaves a column unattributed)
validatts:``p`s`g`u;

/ built-in fallback config - sort every table by time ascending when no config is supplied
defaultparams:([] tabname:enlist`default; att:enlist`; column:enlist`time; sort:enlist 1b);

init:{[deps]
  / wire the injected logger - required, no silent fallback. deps: a dict with a `log key
  / holding a binary `info`warn`error dict of {[c;m]} loggers (context symbol, message string),
  / from di.log or hand-rolled. no adaptation here, so a monadic kx.log instance must be wrapped
  / first. e.g. di.dbwrite.init[enlist[`log]!enlist logdep]
  if[99h<>type deps;
    '"di.dbwrite: deps must be a dict with a `log key"];
  if[not `log in key deps;
    '"di.dbwrite: log dependency is required; pass `info`warn`error functions keyed on `log"];
  if[99h<>type deps`log;
    '"di.dbwrite: log value must be a dict of `info`warn`error functions"];
  if[not all (`info`warn`error) in key deps`log;
    '"di.dbwrite: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  .z.m.loginfo:deps[`log]`info;
  .z.m.logwarn:deps[`log]`warn;
  .z.m.logerr:deps[`log]`error;
  .z.m.sortconfig:(::);
  };

readcsv:{[file]
  / read a sort-config csv and store it in .z.m.sortconfig; used by sort and savedown
  / the csv must have the columns tabname,att,column,sort (in any order)
  / file: hsym, bare symbol, or string path
  if[10h=type file; file:hsym `$file];
  if[-11h=type file; if[not ":" = first string file; file:hsym file]];
  if[not -11h=type file;
    .z.m.logerr[`readcsv;err:"di.dbwrite: readcsv file must be a symbol or string path, got type ",string type file];
    'err;
  ];
  t:parsecsv @[readfile; file; readerr[file]];
  checkconfig t;
  .z.m.loginfo[`readcsv;"read ",(string count t)," sort config row(s) from ",string file];
  .z.m.sortconfig:t;
  };

setconfig:{[t]
  / set .z.m.sortconfig from an in-memory table; alternative to readcsv when config is built in-session
  / t must be a table with columns tabname,att,column,sort
  checkconfig t;
  .z.m.sortconfig:t;
  };

getconfig:{[]
  / return the current sort config stored in .z.m.sortconfig; (::) if not yet set
  :.z.m.sortconfig;
  };

/ internal - protected file read; only the i/o so a genuine read failure gets the readerr message
readfile:{[file]
  / returns the raw csv lines; header validation and parsing happen in parsecsv
  .z.m.loginfo[`readfile;"reading sort config from ",string file];
  :read0 file;
  };

/ internal - log and rethrow a csv read failure
readerr:{[file;e]
  / build the message once, log it under the read context, then rethrow it to the caller
  m:"di.dbwrite: failed to read ",string[file],": ",e;
  .z.m.logerr[`readerr;m];
  'm;
  };

/ internal - parse csv lines into a config table
parsecsv:{[lines]
  / load via 0: - the header row (enlist delim) names the columns, so column order does not
  / matter; cast sort to boolean if present. structural validation is left to checkconfig.
  t:((count "," vs first lines)#"S";enlist",") 0: lines;
  :$[`sort in cols t; update sort:"B"$string sort from t; t];
  };

/ internal - validate a sort-config table, signalling a clear error if it is malformed
checkconfig:{[t]
  / guards every sort call so a hand-built or csv-derived table is rejected early if wrong
  if[98h<>type t;
    .z.m.logerr[`checkconfig;err:"di.dbwrite: config must be a table with columns `tabname`att`column`sort"];
    'err;
  ];
  c:cols t;
  badcols:c where not c in `tabname`att`column`sort;
  if[count badcols;
    .z.m.logerr[`checkconfig;err:"di.dbwrite: unrecognised config column(s): ",", " sv string badcols];
    'err;
  ];
  missingcols:(`tabname`att`column`sort) where not (`tabname`att`column`sort) in c;
  if[count missingcols;
    .z.m.logerr[`checkconfig;err:"di.dbwrite: missing required config column(s): ",", " sv string missingcols];
    'err;
  ];
  if[any null t`tabname;
    .z.m.logerr[`checkconfig;err:"di.dbwrite: config tabname must not be null"];
    'err;
  ];
  if[any null t`column;
    .z.m.logerr[`checkconfig;err:"di.dbwrite: config column must not be null"];
    'err;
  ];
  if[not 1h=type t`sort;
    .z.m.logerr[`checkconfig;err:"di.dbwrite: the sort column must be boolean"];
    'err;
  ];
  badatts:at where not (at:distinct t`att) in validatts;
  if[count badatts;
    .z.m.logerr[`checkconfig;err:"di.dbwrite: unrecognised attribute(s) in att column: ",", " sv string badatts];
    'err;
  ];
  };

sort:{[tabname;dirs]
  / sort and apply attributes to the on-disk partition dirs for one table using .z.m.sortconfig
  / both the sort column order and the att assignments (p/s/g/u) are driven by the config
  / falls back to defaultparams if config has not been set via readcsv or setconfig
  / tabname: symbol; dirs: hsym or list of hsyms (partition directories e.g. from .Q.par)
  config:$[(::)~.z.m.sortconfig; defaultparams; .z.m.sortconfig];
  checkconfig config;
  if[not -11h=type tabname;
    .z.m.logerr[`sort;err:"di.dbwrite: tabname must be a symbol, got type ",string type tabname];
    'err;
  ];
  st:string tabname;
  .z.m.loginfo[`sort;"sorting the ",st," table"];
  sp:getsortparams[config;tabname];
  if[not count sp; :()];
  sortdir[sp] each distinct (),dirs;
  .z.m.loginfo[`sort;"finished sorting the ",st," table"];
  };

/ internal - resolve which config rows apply to a table
getsortparams:{[config;tab]
  / tab is the table-name symbol (NOT a table); named to avoid clashing with the tabname column
  / a table uses its own rows; unlisted tables fall back to the default row, else are skipped
  if[count tabsp:select from config where tabname=tab;
    .z.m.loginfo[`getsortparams;"sort params found for: ",string[tab]];
    :tabsp;
  ];
  if[count defsp:select from config where tabname=`default;
    .z.m.loginfo[`getsortparams;"no sort params for: ",string[tab],"; using defaults"];
    :defsp;
  ];
  .z.m.logwarn[`getsortparams;"no sort params for: ",string[tab],"; skipping sort"];
  :0#config;
  };

/ internal - log a sort failure without rethrowing so remaining partitions still run
sorterr:{[sc;dl;e]
  / a single partition failure should not halt the whole run
  .z.m.logerr[`sorterr;"failed to sort ",string[dl]," by ",(", " sv string sc),": ",e];
  :();
  };

/ internal - sort one partition directory by the given columns
sortcolumns:{[dloc;sortcols]
  / split out of sortdir so the conditional body there stays a single statement
  .z.m.loginfo[`sortcolumns;"sorting ",string[dloc]," by: ",", " sv string sortcols];
  .[xasc;(sortcols;dloc);
    sorterr[sortcols;dloc]];
  };

/ internal - sort columns and apply attributes for a single on-disk partition directory
sortdir:{[sp;dloc]
  / sort by the columns flagged sort=1b, then hand every row to applyattr (it skips non-attributes)
  sortcols:exec column from sp where sort, not null column;
  if[count sortcols; sortcolumns[dloc;sortcols]];
  applyattr[dloc;;]'[sp`column;sp`att];
  };

/ internal - log an attribute application failure without rethrowing
attrerr:{[dl;cn;at;e]
  / logs failure and continues so other columns and partitions still get processed
  .z.m.logerr[`attrerr;"unable to apply ",string[at]," attr to ",string[cn]," in ",string[dl],": ",e];
  :();
  };

applyattr:{[dloc;colname;att]
  / apply a single kdb+ attribute to an on-disk column; logs and swallows errors so a run continues
  / dloc: hsym (partition directory e.g. `:hdb/2024.01.01/trade); colname: symbol; att: symbol (p|s|g|u or empty)
  / skip anything that is not a real attribute - covers the empty none-sentinel and any bad value
  if[not att in `p`s`g`u; :()];
  .z.m.loginfo[`applyattr;"applying ",string[att]," attr to ",string[colname]," in ",string dloc];
  .[{@[x;y;z#]};
    (dloc;colname;att);
    attrerr[dloc;colname;att]];
  };

savedown:{[dir;part;tabname;data]
  / write an in-memory table to a date-partitioned hdb partition, then sort it per .z.m.sortconfig
  / dir: hdb root (hsym); part: partition value (date/month/int); tabname: symbol; data: in-memory table
  / enumerates syms against the hdb sym file; sorting and attributes are driven by .z.m.sortconfig
  .z.m.loginfo[`savedown;"saving ",string[tabname]," partition ",string[part]," to ",string dir];
  path:` sv (.Q.par[dir;part;tabname];`);
  path set .Q.en[dir;data];
  sort[tabname;path];
  .z.m.loginfo[`savedown;"finished saving ",string tabname];
  gc[];
  };

appenddown:{[dir;part;tabname;data]
  / append rows to an existing on-disk partition (enumerates syms); does not sort
  / call sort separately once the partition is complete, to avoid re-sorting on every append
  / dir: hdb root (hsym); part: partition value; tabname: symbol; data: in-memory table
  .z.m.loginfo[`appenddown;"appending ",string[tabname]," partition ",string[part]," in ",string dir];
  path:` sv (.Q.par[dir;part;tabname];`);
  if[not count @[key;path;{`$()}];
    .z.m.logerr[`appenddown;err:"di.dbwrite: appenddown partition does not exist at ",string path];
    'err;
  ];
  .[path;();,;.Q.en[dir;data]];
  .z.m.loginfo[`appenddown;"finished appending ",string tabname];
  };

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
  .z.m.loginfo[`gc;"starting garbage collect. ",memstats[]];
  r:.Q.gc[];
  .z.m.loginfo[`gc;"garbage collection returned ",(string `long$r%1048576),"MB. ",memstats[]];
  };

getapimeta:{[]
  / one row per CALLABLE export, for di.torq to register with di.api. init and getapimeta are
  / omitted as plumbing. names are bare
  :flip `name`public`descrip`params`return!flip(
    (`readcsv;    1b; "read a sort-config csv and store it in module state";
       "[symbol|hsym|string: file]";                                          "table: the stored config");
    (`setconfig;  1b; "store a hand-built sort-config table in module state";
       "[table: t (tabname/att/column/sort)]";                                "table: the stored config");
    (`getconfig;  1b; "return the currently stored sort config";
       "[]";                                                                  "table|generic null: config, or (::) if unset");
    (`sort;       1b; "sort on-disk partition(s) for a table and apply attributes per stored config";
       "[symbol: tabname; hsym|hsym list: dirs]";                             "null");
    (`applyattr;  1b; "apply a single kdb+ attribute (p/s/g/u) to one on-disk column, best-effort";
       "[hsym: dloc; symbol: colname; symbol: att]";                          "null");
    (`savedown;   1b; "write an in-memory table to an hdb partition, sort it, then run gc";
       "[hsym: dir; date|month|int: part; symbol: tabname; table: data]";     "null");
    (`appenddown; 1b; "append rows to an existing on-disk partition without sorting";
       "[hsym: dir; date|month|int: part; symbol: tabname; table: data]";     "null");
    (`version;    1b; "module version string";
       "[]";                                                                  "string: version"));
  };