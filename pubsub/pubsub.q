/ subscription table - no filters
reqalldict:enlist[`]!();

/ subscription table with filters
reqfilteredtbl:([]table:`symbol$();handle:`int$();filts:();columns:());

/ get all subscription handles that haven been recorded on tables
getallhandles:{distinct raze union[value .z.m.reqalldict;exec handle from .z.m.reqfilteredtbl]};

/ add handle to reqalldict dictionary
add:{[t] if[not .z.w in .z.m.reqalldict[t];.z.m.reqalldict[t],:.z.w]};

delhandle:{[t;h]
  / remove handle from request-all-data table
  if[t in key .z.m.reqalldict; @[.z.M.reqalldict;t;except;h]];
  if[not count .z.m.reqalldict[t];.z.m.reqalldict _:t];
  };

/ remove handle from request-filtered-data table
delhandlef:{[t;h]delete from .z.M.reqfilteredtbl where table=t, handle=h};

suball:{[table]
  / subscribe to table without filtering i.e. all data from the subscribed table
  m:(); table,:();
  if[not all table in .z.m.t;
    errmsg:(`$sv[csv;string  m:table except .z.m.t]," not available for subscription.");
    table@:where table in .z.m.t];
  if[count table;
    {delhandle[x;.z.w];
    delhandlef[x;.z.w];
    add[x]} each table;
    :((errmsg;(table;.z.m.schemas[table]));(table;.z.m.schemas[table])) [m~()]];
  errmsg
  };

subfiltered:{[table;filters]
  / subscribe to tables with filter (symbols or custom conditions)
  m:();
  $[99h=type filters;
    table:key[filters] first cols filters; table,:()];
  if[not all table in .z.m.t;
    errmsg: (`$sv[csv;string  m:table except .z.m.t]," not available for subscription");
    table@:where table in .z.m.t];
  if[count table;
    {delhandlef[x;.z.w];
    delhandle[x;.z.w];
    val:![11 99h;(addsymsub;addfiltered)][abs type y] . (x;y)}[;filters] each table;
    :((errmsg;(table;.z.m.schemas[table]));(table;.z.m.schemas[table])) [m~()]];
  errmsg
  };

addfiltered:{[table;cond]
  / subscribe to tables with custom conditions
  / if either filters or columns parsing fails, subscription should not be logged as no half query should be created
  filters:$[all null f:cond[table;`filts];();@[parse;"select from t where ",f;{'"incorrect filters for parsing"}][2]];
  columns:$[all null c:cond[table;`columns];();@[parse;"select ",c," from t";{'"incorrect columns for parsing"}][4]];
  @[eval;(?;.z.m.schemas[table];filters;0b;columns);{'"incorrect query with filters-",.Q.s1[y],"  columns-",.Q.s1[z]," error-",x}[;filters;columns]];
  @[.z.M;`reqfilteredtbl;upsert;(table;.z.w;filters;columns)]
  };

addsymsub:{[table;syms]
  / subscribe to tables with symbols
  filts:enlist enlist (in;`sym;enlist syms);
  @[eval;(?;.z.m.schemas[table];filts;0b;());{'"incompatible with table schema:",string[y]," error-",x}[;syms]];
  @[.z.M;`reqfilteredtbl;upsert;(table;.z.w;filts;())]
  };

closesub:{[h]
  / remove handles upon connection close
  delhandle[;h] each key[.z.m.reqalldict];
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
  if[`~table;table:.z.m.t];
  :$[`~filters;suball;subfiltered[;filters]]table;
  };

publish:{[t;x]
  / single entry point for publishing
  if[not count x;:()];
  if[count h:.z.m.reqalldict[t];-25!(h;(`upd;t;x))];
  if[count d:select from .z.m.reqfilteredtbl where table=t;
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

/ create a list of tables for subscription, allow users to set subscribestrs, otherwise set to null
setsubscribestrs:{@[.z.M;`subscribestrs;:;$[x~`;0#x;x]];};
setsubscribestrs`;

initialized:0b;

init:{
  .z.m.t:$[count .z.m.subscribestrs;.z.m.subscribestrs;tables[]except`reqfilteredtbl];
  .z.m.schemas:.z.m.t!extractschema each .z.m.t;
  .z.m.tabcols:.z.m.t!cols each .z.m.t;
  if[count .z.m.tabcols;@[.z.M;`initialized;:;1b]];
  };
