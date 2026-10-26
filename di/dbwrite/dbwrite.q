/ write, sort and attribute utilities for on-disk data

/ attributes that may legitimately appear in a config (empty leaves a column unattributed)
validatts:``p`s`g`u;

/ fallback sort config: p# on sym, sorted by sym then time
defaultparams:([] tabname:`default`default; att:`p`; column:`sym`time; sort:11b);

/ save down hooks, set by init only when passed
savedownmanipulation:()!();
posthook:{[d;p]};

init:{[deps]
  / wire the required `log dep (`info`warn`error dict of {[c;m]}) and optional save down hooks
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
  if[`savedownmanipulation in key deps;.z.m.savedownmanipulation:deps`savedownmanipulation];
  if[`postreplay in key deps;.z.m.posthook:deps`postreplay];
  };

/ apply the table's savedownmanipulation, if any, keeping the data on failure
manipulate:{[t;x]
  $[t in key .z.m.savedownmanipulation;
    @[.z.m.savedownmanipulation t;x;{[x;e] .z.m.logerr[`manipulate;"save down manipulation failed : ",e];x}[x]];
    x]
  };

/ call the postreplay hook after a partition is written
postreplay:{[d;p] .z.m.posthook[d;p]};

readcsv:{[file]
  / store a tabname,att,column,sort csv as the sort config; file: hsym, symbol or string path
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
  / store a tabname,att,column,sort table as the sort config
  checkconfig t;
  .z.m.sortconfig:t;
  };

getconfig:{[]
  / current sort config; (::) if not set
  :.z.m.sortconfig;
  };

/ internal - read the raw csv lines
readfile:{[file]
  .z.m.loginfo[`readfile;"reading sort config from ",string file];
  :read0 file;
  };

/ internal - log and rethrow a csv read failure
readerr:{[file;e]
  m:"di.dbwrite: failed to read ",string[file],": ",e;
  .z.m.logerr[`readerr;m];
  'm;
  };

/ internal - parse csv lines into a config table
parsecsv:{[lines]
  / columns named by the header row; sort cast to boolean
  t:((count "," vs first lines)#"S";enlist",") 0: lines;
  :$[`sort in cols t; update sort:"B"$string sort from t; t];
  };

/ internal - signal if a sort-config table is malformed
checkconfig:{[t]
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
  / sort and apply attributes to a table's partition dirs per the sort config, or defaultparams if unset
  / tabname: symbol; dirs: hsym or list of hsyms
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
  / tab: table name; its own rows, else the default rows, else none
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

/ internal - log a sort failure without rethrowing
sorterr:{[sc;dl;e]
  .z.m.logerr[`sorterr;"failed to sort ",string[dl]," by ",(", " sv string sc),": ",e];
  :();
  };

/ internal - sort one partition directory by the given columns
sortcolumns:{[dloc;sortcols]
  .z.m.loginfo[`sortcolumns;"sorting ",string[dloc]," by: ",", " sv string sortcols];
  .[xasc;(sortcols;dloc);
    sorterr[sortcols;dloc]];
  };

/ internal - sort columns and apply attributes for a single on-disk partition directory
sortdir:{[sp;dloc]
  / sort by the columns flagged sort, then apply each row's attribute
  sortcols:exec column from sp where sort, not null column;
  if[count sortcols; sortcolumns[dloc;sortcols]];
  applyattr[dloc;;]'[sp`column;sp`att];
  };

/ internal - log an attribute application failure without rethrowing
attrerr:{[dl;cn;at;e]
  .z.m.logerr[`attrerr;"unable to apply ",string[at]," attr to ",string[cn]," in ",string[dl],": ",e];
  :();
  };

applyattr:{[dloc;colname;att]
  / apply an attribute to an on-disk column, logging any error; dloc: partition dir hsym; att: p|s|g|u or empty
  if[not att in `p`s`g`u; :()];
  .z.m.loginfo[`applyattr;"applying ",string[att]," attr to ",string[colname]," in ",string dloc];
  .[{@[x;y;z#]};
    (dloc;colname;att);
    attrerr[dloc;colname;att]];
  };

savedown:{[dir;part;tabname;data]
  / enumerate and write a table to an hdb partition, then sort it; dir: hdb root hsym; part: partition value
  .z.m.loginfo[`savedown;"saving ",string[tabname]," partition ",string[part]," to ",string dir];
  path:` sv (.Q.par[dir;part;tabname];`);
  path set .Q.en[dir;manipulate[tabname;data]];
  sort[tabname;path];
  .z.m.loginfo[`savedown;"finished saving ",string tabname];
  gc[];
  };

appenddown:{[dir;part;tabname;data]
  / enumerate and append rows to an existing partition, without sorting
  .z.m.loginfo[`appenddown;"appending ",string[tabname]," partition ",string[part]," in ",string dir];
  path:` sv (.Q.par[dir;part;tabname];`);
  if[not count @[key;path;{`$()}];
    .z.m.logerr[`appenddown;err:"di.dbwrite: appenddown partition does not exist at ",string path];
    'err;
  ];
  .[path;();,;.Q.en[dir;manipulate[tabname;data]]];
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