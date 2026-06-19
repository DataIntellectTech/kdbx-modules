/ library for sorting and applying attributes to on-disk kdb+ tables

/ attributes that may legitimately be applied on disk (empty leaves a column unattributed)
validatts:``p`s`g`u;

init:{[deps]
  / wire the injectable log dependency so the module reports through the host's logger
  / deps: a dict with a `log key -> `info`warn`error!({[c;m]};{[c;m]};{[c;m]})
  / see di.log for a default implementation, or pass any matching dict
  / example: srt.init[enlist[`log]!enlist logdep]
  if[99h<>type deps;
    '"di.sort: deps must be a dict with a `log key; see di.log for a default logger"];
  if[not `log in key deps;
    '"di.sort: log dependency is required; pass `info`warn`error functions keyed on `log"];
  if[99h<>type deps`log;
    '"di.sort: log value must be a dict of `info`warn`error functions"];
  if[not all (`info`warn`error) in key deps`log;
    '"di.sort: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  .z.m.log:deps`log;
  };

readcsv:{[file]
  / convenience for the common case where config lives in a csv - returns it, does not store
  / pass the result to sorttab, e.g. srt.sorttab[srt.readcsv `:sort.csv;`trade;dirs]
  / the csv must have columns tabname,att,column,sort in that order
  file:hsym file;
  t:@[readfile; file; readerr[file]];
  .z.m.log[`info][`readcsv;"read ",(string count t)," sort param row(s) from ",string file];
  :t;
  };

/ internal - read and parse a sort-config csv (the protected action in readcsv)
readfile:{[file]
  / kept named rather than inline so readcsv reads cleanly and matches the style guide
  .z.m.log[`info][`readcsv;"reading sort params from ",string file];
  :("SSSB";enlist",") 0: file;
  };

/ internal - log and rethrow a csv read failure
readerr:{[file;e]
  / surfaces the failure to the caller after logging it under the readcsv context
  .z.m.log[`error][`readcsv;"failed to read ",string[file],": ",e];
  '"failed to read ",string[file],": ",e;
  };

sorttab:{[config;tabname;dirs]
  / sort and apply attributes to the on-disk partition directories for one table
  / config: a sort-config table (build it directly or via readcsv); tabname: symbol; dirs: hsym or list of hsyms
  / example: srt.sorttab[srt.readcsv `:sort.csv;`trade;`:/hdb/2024.01.01/trade]
  checkconfig config;
  st:string tabname;
  .z.m.log[`info][`sorttab;"sorting the ",st," table"];
  sp:getsortparams[config;tabname;st];
  if[not count sp; :()];
  sortdir[sp] each distinct (),dirs;
  .z.m.log[`info][`sorttab;"finished sorting the ",st," table"];
  };

/ internal - validate a sort-config table, signalling a clear error if it is malformed
checkconfig:{[t]
  / guards every sorttab call so a hand-built or csv-derived table is rejected early if wrong
  if[98h<>type t;
    '"di.sort: config must be a table with columns `tabname`att`column`sort"];
  c:cols t;
  badcols:c where not c in `tabname`att`column`sort;
  if[count badcols;
    '"di.sort: unrecognised config column(s): ",", " sv string badcols];
  missingcols:(`tabname`att`column`sort) where not (`tabname`att`column`sort) in c;
  if[count missingcols;
    '"di.sort: missing required config column(s): ",", " sv string missingcols];
  if[not 1h=type t`sort;
    '"di.sort: the sort column must be boolean"];
  badatts:at where not (at:distinct t`att) in validatts;
  if[count badatts;
    '"di.sort: unrecognised attribute(s) in att column: ",", " sv string badatts];
  };

/ internal - log a sorttab message then return the resolved rows
logreturn:{[lvl;msg;rows]
  / keeps each branch body in getsortparams to a single statement
  .z.m.log[lvl][`sorttab;msg];
  :rows;
  };

/ internal - resolve which config rows apply to a table
getsortparams:{[config;t;st]
  / a table uses its own rows; unlisted tables fall back to the default row, else are skipped
  if[count tabsp:select from config where tabname=t;
    :logreturn[`info;"sort parameters have been retrieved for: ",st;tabsp]];
  if[count defsp:select from config where tabname=`default;
    :logreturn[`info;"no sort parameters have been specified for: ",st,". using default parameters";defsp]];
  :logreturn[`warn;"no sort parameters have been found for: ",st,". the table will not be sorted";0#config];
  };

/ internal - log a sort failure without rethrowing so remaining partitions still run
sorterr:{[sc;dl;e]
  / a single partition failure should not halt the whole run
  .z.m.log[`error][`sorttab;"failed to sort ",string[dl]," by these columns: ",(", " sv string sc),". the error was: ",e];
  :();
  };

/ internal - sort one partition directory by the given columns
sortcolumns:{[dloc;sortcols]
  / split out of sortdir so the conditional body there stays a single statement
  .z.m.log[`info][`sorttab;"sorting ",string[dloc]," by these columns: ",", " sv string sortcols];
  .[xasc;(sortcols;dloc);
    sorterr[sortcols;dloc]];
  };

/ internal - sort columns and apply attributes for a single on-disk partition directory
sortdir:{[sp;dloc]
  / sort by the columns flagged sort=1b, then attribute the columns that request one
  sortcols:exec column from sp where sort, not null column;
  if[count sortcols; sortcolumns[dloc;sortcols]];
  attrcols:select column,att from sp where not null att;
  if[count attrcols; applyattr[dloc;;]'[attrcols`column;attrcols`att]];
  };

/ internal - log an attribute application failure without rethrowing
attrerr:{[dl;cn;at;e]
  / logs failure and continues so other columns and partitions still get processed
  .z.m.log[`error][`applyattr;"unable to apply ",string[at]," attr to the ",string[cn]," column in ",string[dl],". the error was: ",e];
  :();
  };

/ internal - apply a single attribute to a specific column in an on-disk partition
applyattr:{[dloc;colname;att]
  / sortdir only passes non-null atts; guard here in case applyattr is ever called directly
  if[null att; :()];
  .z.m.log[`info][`applyattr;"applying ",string[att]," attr to the ",string[colname]," column in ",string dloc];
  .[{@[x;y;z#]};
    (dloc;colname;att);
    attrerr[dloc;colname;att]];
  };
