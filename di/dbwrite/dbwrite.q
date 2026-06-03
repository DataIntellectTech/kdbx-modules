/ sort params table - default row sorts all tables by time ascending
params:([] tabname:enlist`default; att:enlist`; column:enlist`time; sort:enlist 1b);

/ save-down manipulation registry: tabname -> unary function
savedownmanipulation:()!();

/ load and validate sort.csv into .z.M.params
/ file: hsym path; null warns and resets params to default row
loadconfig:{[file]
  if[not -11h=type file;
    '"loadconfig: file must be a symbol, got type ",(string type file)];
  if[null file;
    .z.m.logwarn[`dbwrite;"loadconfig called with no file; resetting params to default"];
    @[.z.M;`params;:;([] tabname:enlist`default; att:enlist`; column:enlist`time; sort:enlist 1b)]];
  if[not null file;
    file:hsym file;
    p:@[
      {.z.m.loginfo[`dbwrite;"retrieving sort settings from ",string x];("SSSB";enlist",")0:x};
      file;
      {[f;e]'"failed to open ",string[f],": ",e}[file]
    ];
    if[not all spcb:(spc:cols p) in `tabname`att`column`sort;
      '"unrecognised columns (",(", " sv string spc where not spcb),") in ",string file];
    if[not all atb:(at:distinct p`att) in ``p`s`g`u;
      '"unrecognised attribute(s): ",", " sv string at where not atb];
    @[.z.M;`params;:;p]];
  };

/ apply a single kdb+ attribute to an on-disk column; logs and swallows errors
applyattr:{[dloc;colname;att]
  .z.m.loginfo[`dbwrite;"applying ",string[att]," attr to ",string[colname]," in ",string dloc];
  if[null colname;
    .z.m.logerr[`dbwrite;"applyattr called with null column name in ",string dloc]];
  if[not null colname;
    $[not att in `p`s`g`u;
      .z.m.logerr[`dbwrite;"applyattr: invalid attribute ",string[att]," for ",string[colname]," in ",string dloc];
      .[{@[x;y;z#]};(dloc;colname;att);
        {[dloc;colname;att;e]
          .z.m.logerr[`dbwrite;"unable to apply ",string[att]," attr to ",string[colname]," in ",string[dloc],": ",e]
        }[dloc;colname;att]
      ]]];
  };

/ sort an on-disk table partition and apply attributes per sort.csv config
/ d: tabname | (tabname;dir) | (tabname;list of dirs)
sort:{[d]
  $[not count d;
    ();
    not (type d) in -11 0 11h;
    [.z.m.logerr[`dbwrite;"sort: d must be a symbol or list, got type ",(string type d)];()];
    [
      .z.m.loginfo[`dbwrite;"sorting ",(st:string t:first d)," table"];
      sp:$[count tabsp:select from .z.M.params where tabname=t;
          [.z.m.loginfo[`dbwrite;"sort params found for: ",st];tabsp];
        count defsp:select from .z.M.params where tabname=`default;
          [.z.m.logwarn[`dbwrite;"no sort params for: ",st,"; using defaults"];defsp];
        [.z.m.logwarn[`dbwrite;"no sort params for: ",st,"; skipping sort"];:()]];
      {[sp;dloc]
        if[count sortcols:exec column from sp where sort,not null column;
          .z.m.loginfo[`dbwrite;"sorting ",string[dloc]," by: ",", " sv string sortcols];
          .[xasc;(sortcols;dloc);
            {[sc;dl;e]
              .z.m.logerr[`dbwrite;"failed to sort ",string[dl]," by ",(", " sv string sc),": ",e]
            }[sortcols;dloc]]];
        if[count attrcols:select column,att from sp where not null att;
          .z.M.applyattr[dloc;;]'[attrcols`column;attrcols`att]];
      }[sp] each distinct (),last d;
      .z.m.loginfo[`dbwrite;"finished sorting ",st," table"]
    ]]
  };

/ apply registered pre-write manipulation to table x of type t
/ returns modified table; on error logs and returns original unmodified table
manipulate:{[t;x]
  $[t in key .z.M.savedownmanipulation;
    @[.z.M.savedownmanipulation[t];x;
      {[x;e].z.m.logerr[`dbwrite;"save-down manipulation failed: ",e];x}[x]];
    x]
  };

/ post-EOD hook - called after all tables written and sorted
/ d: hdb directory (hsym), p: partition value (date)
/ stub: override at the call site to add custom post-replay logic
postreplay:{[d;p]};

/ format current process memory stats as a loggable string
memstats:{[]"mem stats: ",{"; "sv "=" sv'flip(string key x;(string value x),\:" MB")}`long$.Q.w[]%1048576};

/ run .Q.gc[] and log before/after memory stats
gc:{
  .z.m.loginfo[`dbwrite;"starting garbage collect. ",.z.M.memstats[]];
  r:.Q.gc[];
  .z.m.loginfo[`dbwrite;"garbage collection returned ",(string `long$r%1048576),"MB. ",.z.M.memstats[]]
  };

init:{[config;deps]
  / config: dict with optional keys
  /   `savedownmanipulation: tabname!function dict of pre-write manipulation functions
  / deps: `log!(logdict)
  /   `log: `info`warn`error!(infofunc;warnfunc;errfunc) - required
  logdict:$[99h=type deps;$[(`log in key deps) and not (::)~deps`log;deps`log;()!()];()!()];
  if[not count logdict;
    '"di.dbwrite: log dependency is required; pass `info`warn`error functions - see di.log or refer to confluence documentation";
  ];
  .z.m.loginfo:logdict`info;
  .z.m.logwarn:logdict`warn;
  .z.m.logerr:logdict`error;
  };
