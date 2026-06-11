/ library for sorting and applying attributes to on-disk kdb+ tables

/ sort configuration table - populated by getsortcsv, read via getparams
params:([] tabname:`symbol$(); att:`symbol$(); column:`symbol$(); sort:`boolean$());

/ valid attribute symbols accepted in sort.csv att column
validatts:``p`s`g`u;

init:{[deps]
  / wire injectable log dependency (required) and optional config from deps dict
  / optional keys: `savedir - hsym path to sort.csv, defaults to `:sort.csv
  logdict:$[99h=type deps;
    $[`log in key deps;
      $[99h=type deps`log; deps`log; ()!()];
      ()!()];
    ()!()];
  if[not count logdict;
    '"di.sort: log dependency is required; pass `info`warn`error functions - ",
     "see di.log for a default implementation or refer to confluence documentation";
  ];
  .z.m.loginfo:logdict`info;
  .z.m.logwarn:logdict`warn;
  .z.m.logerr:logdict`error;
  .z.m.defaultfile:$[`savedir in key deps; deps`savedir; `:sort.csv];
  };

/ internal - log and rethrow a csv load error
csvloaderr:{[f;e]
  / logs the failure then rethrows so getsortcsv surfaces the error to the caller
  .z.m.logerr[`getsortcsv;"failed to open ",string[f],". the error was: ",e];
  '"failed to open ",string[f],". the error was: ",e;
  };

getsortcsv:{[file]
  / load and validate sort configuration from a CSV file; populates the params table
  file:hsym file;
  rawparams:@[
    {.z.m.loginfo[`getsortcsv;"retrieving sort settings from ",string x]; ("SSSB";enlist",")0:x};
    file;
    csvloaderr[file]
  ];
  spc:cols rawparams;
  badcols:spc where not spc in `tabname`att`column`sort;
  if[count badcols;
    '"unrecognised columns (",(", " sv string badcols),") in ",string file];
  missingcols:(`tabname`att`column`sort) where not (`tabname`att`column`sort) in spc;
  if[count missingcols;
    '"missing required columns (",(", " sv string missingcols),") in ",string file];
  at:distinct rawparams`att;
  badatts:at where not at in validatts;
  if[count badatts;
    '"unrecognised type of attribute - ",(", " sv string badatts)];
  .z.m.params:rawparams;
  .z.m.loginfo[`getsortcsv;"loaded ",(string count rawparams)," sort config rows from ",string file];
  };

sorttab:{[d]
  / sort and apply attributes to on-disk partitions for one table
  st:string t:first d;
  if[0=count params; getsortcsv[.z.m.defaultfile]];
  .z.m.loginfo[`sorttab;"sorting the ",st," table"];
  sp:getsortparams[t;st];
  if[not count sp; :()];
  sortdir[sp] each distinct (),last d;
  .z.m.loginfo[`sorttab;"finished sorting the ",st," table"];
  };

getparams:{[]
  / return the current sort configuration table
  :params;
  };

/ internal - look up sort params for a table, falling back to the default row
getsortparams:{[t;st]
  / return table-specific params, then default row, then empty table if neither found
  if[count tabsp:select from params where tabname=t;
    .z.m.loginfo[`sorttab;"sort parameters have been retrieved for: ",st];
    :tabsp];
  if[count defsp:select from params where tabname=`default;
    .z.m.loginfo[`sorttab;"no sort parameters have been specified for: ",st,". using default parameters"];
    :defsp];
  .z.m.logwarn[`sorttab;"no sort parameters have been found for: ",st,". the table will not be sorted"];
  :0#params;
  };

/ internal - log a sort failure without rethrowing so remaining partitions still run
sorterr:{[sc;dl;e]
  / called as error handler in sortdir; best-effort — a single partition failure should not halt the run
  .z.m.logerr[`sorttab;"failed to sort ",string[dl]," by these columns: ",(", " sv string sc),". the error was: ",e];
  :();
  };

/ internal - sort columns and apply attributes for a single on-disk partition directory
sortdir:{[sp;dloc]
  / sort by columns flagged sort=1b, then apply attributes to columns with a non-null att
  if[count sortcols:exec column from sp where sort, not null column;
    .z.m.loginfo[`sorttab;"sorting ",string[dloc]," by these columns: ",", " sv string sortcols];
    .[xasc;(sortcols;dloc);
      sorterr[sortcols;dloc]]];
  if[count attrcols:select column,att from sp where not null att;
    applyattr[dloc;;]'[attrcols`column;attrcols`att]];
  };

/ internal - log an attribute application failure without rethrowing
attrerr:{[dl;cn;at;e]
  / called as error handler in applyattr; logs failure and continues
  .z.m.logerr[`applyattr;"unable to apply ",string[at]," attr to the ",string[cn]," column in ",string[dl],". the error was: ",e];
  :();
  };

/ internal - apply a single attribute to a specific column in an on-disk partition
applyattr:{[dloc;colname;att]
  / null attributes are filtered upstream by sorttab; guard here for safety
  if[null att; :()];
  .z.m.loginfo[`applyattr;"applying ",string[att]," attr to the ",string[colname]," column in ",string dloc];
  .[{@[x;y;z#]};
    (dloc;colname;att);
    attrerr[dloc;colname;att]];
  };
