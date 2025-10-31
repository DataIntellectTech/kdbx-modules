/ subscription table - no filters
reqalldict:enlist[`]!();

/ subscription table with filters
reqfilteredtbl:([]table:`symbol$();handle:`int$();filts:();columns:());

/ get all subscription handles that haven been recorded on tables
getallhandles:{distinct raze union[value reqalldict;exec handle from reqfilteredtbl]};

/ add handle to reqalldict dictionary
add:{[t] if[not .z.w in reqalldict t;reqalldict[t],:.z.w]};

delhandle:{[t;h]
  / remove handle from request-all-data table
  if[t in key reqalldict;@[.z.M.reqalldict;t;except;h]];
  if[not count reqalldict[t];reqalldict _:t];
  };

/ remove handle from request-filtered-data table
delhandlef:{[t;h]delete from .z.M.reqfilteredtbl where table=t, handle=h};

suball:{[table]
  / subscribe to table without filtering i.e. all data from the subscribed table
  m:(); table,:();
  if[not all table in t;
    errmsg:(`$sv[csv;string  m:table except t]," not available for subscription.");
    table@:where table in t];
  if[count table;
    {delhandle[x;.z.w];
    delhandlef[x;.z.w];
    add[x]} each table;
    :((errmsg;(table;schemas table));(table;schemas table))[m~()]];
  errmsg
  };

subfiltered:{[table;filters]
  / subscribe to tables with filter (symbols or custom conditions)
  m:();
  $[99h=type filters;
    table:key[filters] first cols filters; table,:()];
  if[not all table in t;
    errmsg: (`$sv[csv;string  m:table except t]," not available for subscription");
    table@:where table in t];
  if[count table;
    {delhandlef[x;.z.w];
    delhandle[x;.z.w];
    val:![11 99h;(addsymsub;addfiltered)][abs type y] . (x;y)}[;filters] each table;
    :((errmsg;(table;schemas table));(table;schemas table)) [m~()]];
  errmsg
  };

addfiltered:{[table;cond]
  / subscribe to tables with custom conditions
  / if either filters or columns parsing fails, subscription should not be logged as no half query should be created
  filters:$[all null f:cond[table;`filts];();@[parse;"select from t where ",f;{'"incorrect filters for parsing"}][2]];
  columns:$[all null c:cond[table;`columns];();@[parse;"select ",c," from t";{'"incorrect columns for parsing"}][4]];
  @[eval;(?;schemas table;filters;0b;columns);{'"incorrect query with filters-",.Q.s1[y],"  columns-",.Q.s1[z]," error-",x}[;filters;columns]];
  @[.z.M;`reqfilteredtbl;upsert;(table;.z.w;filters;columns)]
  };

addsymsub:{[table;syms]
  / subscribe to tables with symbols
  filts:enlist enlist (in;`sym;enlist syms);
  @[eval;(?;schemas table;filts;0b;());{'"incompatible with table schema:",string[y]," error-",x}[;syms]];
  @[.z.M;`reqfilteredtbl;upsert;(table;.z.w;filts;())]
  };

closesub:{[h]
  / remove handles upon connection close
  delhandle[;h]each key reqalldict;
  delete from .z.M.reqfilteredtbl where handle=h;
  };

/ define .z.pc, add bespoke actions as needed
.z.pc:{closesub[x]};

/ broadcast to all subscribers upon end of day, client needs to define endofday function
callendofday:{(neg getallhandles[])@\:`endofday`};

/ broadcast to all subscribers upon end of period, client needs to define endofperiod function
callendofperiod:{(neg getallhandles[])@\:`endofperiod`};

/ get table schema
extractschema:{[table]0#value table};

subscribe:{[table;filters]
  / single entry point for subscriptions: uses default list when no table name provided; routes to suball if filters null, otherwise subfiltered
  if[`~table;table:t];
  :$[`~filters;suball;subfiltered[;filters]]table;
  };

publish:{[t;x]
  / single entry point for publishing
  if[not count x;:()];
  if[count h:reqalldict t;-25!(h;(`upd;t;x))];
  if[count d:select from reqfilteredtbl where table=t;
    {if[count filtered:eval(?;y;z`filts;0b;z`columns);neg[z`handle](`upd;x;filtered)]}[t;x;] each d];
  };

pubclear:{[t]
  / publish tables and clear up the contents
  publish'[t;value each t,:()];
  @[`.;;0#] each t;
  };

subscribestr:{[table;syms]
  / allow non-kdb+ process to subscribe to tables with/without symbols
  res:subscribe[`$table;$[count syms;`$vs[csv;syms];`]];
  :$[10h~type last res;'last res;res];
  };

subscribestrfilter:{[table;filters;columns]
  / allow non-kdb+ process to subscribe to tables with custom conditions
  res:subscribe[`$table;1!enlist `table`filts`columns!(`$table;filters;columns)];
  :$[10h~type last res;'last res;res];
  };

/ create a list of tables for subscription, allow users to set subtables, otherwise set to null
setsubtables:{.z.m.subtables:$[x~`;0#x;x]};
setsubtables`;

initialized:0b;

init:{
  .z.m.t:$[count subtables;subtables;tables[]except`reqfilteredtbl];
  .z.m.schemas:t!extractschema each t;
  .z.m.tabcols:t!cols each t;
  if[count tabcols;.z.m.initialized:1b];
  };
