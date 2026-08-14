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

/ define .z.pc, add bespoke actions as needed.
/ CHAINS onto whatever already owns .z.pc rather than replacing it. a bare .z.pc:{closesub[x]} here
/ silently destroyed every observer another module had already registered - measured: with a
/ di.handlers registration in place first, loading this module stopped it firing while di.handlers
/ went on listing it as registered, so the failure was invisible from the registry.
/ this stays a raw assignment rather than a di.handlers registration because the modularisation
/ plan classifies di.pubsub as STANDALONE - it takes no injected dependencies, so it cannot reach
/ di.handlers without contradicting its own tier
priorpc:@[value;`.z.pc;{[e] (::)}];
.z.pc:{[w]
  closesub[w];
  if[not (::)~priorpc;priorpc w];
  };

/ broadcast to all subscribers upon end of day, client needs to define endofday function
callendofday:{[d](neg getallhandles[])@\:(`endofday;d)};

/ broadcast to all subscribers upon end of period, client needs to define endofperiod function
callendofperiod:{(neg getallhandles[])@\:(`endofperiod;x)};

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

raisenosub:{[res]
  / internal - signal when a subscribe matched NOTHING, for the string entry points below.
  / subscribe returns one of three shapes: (tables;schemas) when every requested table exists,
  / (errmsg;(tables;schemas)) when only some do, or a bare errmsg SYMBOL when none do. the string
  / entry points exist for non-kdb+ clients, which cannot inspect a q result shape - so a request
  / that subscribed to nothing has to arrive as an error, not as a value that merely reads like one.
  / the partial case deliberately still RETURNS: those tables really were subscribed, and signalling
  / would tell the caller it failed while leaving it registered.
  / NB this replaces a guard (10h~type last res) that could never fire - errmsg is built with `$ so it
  / is a symbol, and `last` of either success shape is the schema list, never a 10h string
  if[-11h=type res;'string res];
  :res;
  };

subscribestr:{[table;syms]
  / allow non-kdb+ process to subscribe to tables with/without symbols
  res:subscribe[`$table;$[count syms;`$vs[csv;syms];`]];
  :raisenosub res;
  };

subscribestrfilter:{[table;filters;columns]
  / allow non-kdb+ process to subscribe to tables with custom conditions
  res:subscribe[`$table;1!enlist `table`filts`columns!(`$table;filters;columns)];
  :raisenosub res;
  };

/ create a list of tables for subscription, allow users to set subtables, otherwise set to null
setsubtables:{.z.m.subtables:$[x~`;0#x;x]};

getsubtables:{[]
  / the tables currently available for subscription. the read counterpart to setsubtables, which
  / REPLACES the list - a consumer that needs to ADD to the publish set has no other way to learn the
  / current one, and reaching into module state from outside is not an interface.
  / empty until init has run, rather than signalling on an unset name
  / read .z.m.t EXPLICITLY - a bare t would resolve to the same module state, but the explicit form is
  / the one qlint accepts and matches how every other module reads its own state
  :@[{[] .z.m.t};::;{[e] `symbol$()}];
  };
setsubtables`;

initialized:0b;

init:{
  .z.m.t:$[count subtables;subtables;tables[]except`reqfilteredtbl];
  .z.m.schemas:t!extractschema each t;
  .z.m.tabcols:t!cols each t;
  if[count tabcols;.z.m.initialized:1b];
  };
