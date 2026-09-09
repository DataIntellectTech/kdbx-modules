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

/ chains onto any existing .z.pc rather than replacing it - a bare .z.pc:{closesub[x]} here
/ silently destroyed other modules' registered observers (measured). raw assignment, not a
/ di.handlers registration, because this runs at LOAD time before init exists to depend on
priorpc:@[value;`.z.pc;{[e] (::)}];
.z.pc:{[w]
  closesub[w];
  if[not (::)~priorpc;priorpc w];
  };

/ broadcast to all subscribers upon end of day, client needs to define endofday function
callendofday:{[d](neg getallhandles[])@\:(`endofday;d)};

/ broadcast to all subscribers upon end of period - TERNARY (currentperiod;nextperiod;data),
/ matching legacy and its real subscribers (rdb.q, wdb.q). NB callendofday stays unary - its
/ subscriber doesn't use the second legacy argument, so don't "fix" that one for symmetry
callendofperiod:{[currentperiod;nextperiod;data](neg getallhandles[])@\:(`endofperiod;currentperiod;nextperiod;data)};

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
  / internal - signal when a subscribe matched NOTHING, for the string entry points below. subscribe
  / returns (tables;schemas), (errmsg;(tables;schemas)) for a partial match, or a bare errmsg symbol
  / for none - a non-kdb+ caller cannot inspect a q result shape, so "nothing subscribed" must arrive
  / as an error. the partial case still RETURNS: those tables really were subscribed
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
  / the tables currently available for subscription - the read counterpart to setsubtables, which
  / REPLACES the list rather than adding to it. empty until init has run, rather than signalling
  / on an unset name
  :@[{[] .z.m.t};::;{[e] `symbol$()}];
  };
setsubtables`;

initialized:0b;

iscallable:{[x]
  / internal - is x a genuinely callable value? 100 112h spans every callable form, but 101h - the
  / generic null :: - sits INSIDE that range while being callable in no useful sense, and :: is
  / exactly what a dep dict hands back for a missing key. see di.servers' identical helper
  t:type x;
  (t within 100 112h) and 101h<>t
  };

init:{[deps]
  / deps: OPTIONAL, unlike every other DI'd module - pubsub[`init][] (unary, no args) keeps working.
  / an OPTIONAL `handlers` key additionally registers closesub as a NAMED .z.pc observer, so
  / di.handlers.list[`.z.pc] lists `pubsub - closing the gap where the raw chain above stayed
  / correctly wired but invisible to the registry.
  / the raw chain keeps running regardless of `handlers` - it fires at LOAD time, before init exists
  / to gate it - which is safe because closesub is idempotent, so a double dispatch on one disconnect
  / is a no-op.
  / re-registers on EVERY call that supplies handlers - no one-shot latch. di.handlers.register is
  / itself idempotent by name, so this costs nothing on a re-init; a latch would instead silently
  / swallow a later call meaning to re-point pubsub at a different handlers instance
  if[not (::)~deps;
    if[99h<>type deps;'"di.pubsub: deps, if given, must be a dict"];
    if[`handlers in key deps;
      if[not iscallable deps[`handlers]`register;
        '"di.pubsub: handlers`register must be a function [event;phase;name;priority;func] - see di.handlers"];
      (deps[`handlers][`register])[`.z.pc;`;`pubsub;0j;closesub]]];
  .z.m.t:$[count subtables;subtables;tables[]except`reqfilteredtbl];
  .z.m.schemas:t!extractschema each t;
  .z.m.tabcols:t!cols each t;
  if[count tabcols;.z.m.initialized:1b];
  };
