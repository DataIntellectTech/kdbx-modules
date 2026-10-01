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
  / remove handles upon connection close. NOT bound to .z.pc here: a load-time .z.pc assignment from
  / this module replaced whatever the process had already bound (e.g. the di.torq.handlers dispatcher
  / carrying di.torq.servers' cleanup hook), so the consumer binds it - via its handlers dependency in
  / a di.torq process, or .z.pc:pubsub.closesub in a bare one
  delhandle[;h]each key reqalldict;
  delete from .z.M.reqfilteredtbl where handle=h;
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

init:{[deps]
  if[99h<>type deps;'"di.pubsub: deps must be a dict with a log key"];
  if[not `log in key deps;'"di.pubsub: log dependency is required - see di.util.log"];
  .z.m.log:deps`log;
  .z.m.t:$[count subtables;subtables;tables[]except`reqfilteredtbl];
  .z.m.schemas:t!extractschema each t;
  .z.m.tabcols:t!cols each t;
  if[count tabcols;.z.m.initialized:1b];
  };

/ .stpps, .u.sub, .ps
\d .stpps

t:`
subrequestall:enlist[`]!enlist ()
subrequestfiltered:([]tbl:`$();handle:`int$();filts:();columns:())

endp:{
  (neg allsubhandles[])@\:(`endofperiod;x;y;z);
 };

end:{
  (neg allsubhandles[])@\:(`endofday;x;y);
 };

allsubhandles:{
  distinct raze union/[value subrequestall;exec handle from .stpps.subrequestfiltered]
  };

suball:{
  delhandle[x;.z.w];
  add[x];
  :(x;schemas[x]);
 };

subfiltered:{[x;y]
  delhandlef[x;.z.w];
  val:![11 99h;(selfiltered;addfiltered)][type y] . (x;y);
  $[all raze null val;(x;schemas[x]);val]
 };

add:{
  if[not (count subrequestall x)>i:subrequestall[x]?.z.w;
    subrequestall[x],:.z.w];
 };

errparse:{.z.m.log[`error][`addfiltered;m:y," error: ",x];'m};

addfiltered:{[x;y]
  filters:$[all null f:y[x;`filters];();@[parse;"select from t where ",f;.stpps.errparse[;"Filter"]] 2];
  columns:last $[all null c:y[x;`columns];();@[parse;"select ",c," from t";.stpps.errparse[;"Column"]]];
  @[eval;(?;.stpps.schemas[x];filters;0b;columns);.stpps.errparse[;"Query"]];
  `.stpps.subrequestfiltered upsert (x;.z.w;filters;columns);
 };

selfiltered:{[x;y]
  filts:enlist enlist (in;`sym;enlist y);
  @[eval;(?;.stpps.schemas[x];filts;0b;());.stpps.errparse[;"Query"]];
  `.stpps.subrequestfiltered upsert (x;.z.w;filts;());
 };

pub:{[t;x]
  if[not count x;:()];
  if[count h:subrequestall[t];-25!(h;(`upd;t;x))];
  if[t in .stpps.subrequestfiltered`tbl;
    {[t;x;sels] data:eval(?;x;sels`filts;0b;sels`columns);
         if[count data;neg[sels`handle](`upd;t;data)]}[t;x;]
           each select handle,filts,columns from .stpps.subrequestfiltered where tbl=t
    ];
   };

pubclear:{
 .stpps.pub'[x;value each x,:()];
 @[`.;x;:;.stpps.schemasnoattributes[x]];
 }

delhandle:{[t;h]
  @[`.stpps.subrequestall;t;except;h];
 };

delhandlef:{[t;h]
  delete from  `.stpps.subrequestfiltered where tbl=t,handle=h;
 };

closesub:{[h]
  delhandle[;h]each t;
  delhandlef[;h]each t;
 };

extractschema:{t:value x; $[.Q.qp t; t; 0#t]};

attrstrip:{[t]
  {@[x;cols x;`#]} each .stpps.t:t;
  .stpps.schemasnoattributes:.stpps.t!extractschema each .stpps.t;
 };

init:{[t]
  if[count b:t where not t in tables[];{.z.m.log[`error][`psinit;m:"Table ",string[x]," does not exist"];'m} each b];
  .stpps.t:t except b;
  .stpps.schemas:.stpps.t!extractschema each .stpps.t;
  .stpps.tabcols:.stpps.t!cols each .stpps.t;
 };

\d .

.u.sub:{[x;y]
  if[x~`;:.z.s[;y] each .stpps.t];
  if[not x in .stpps.t;
    .z.m.log[`error][`sub;m:"Table ",string[x]," not in list of stp pub/sub tables"];
    :(x;m)
  ];
  $[y~`;.stpps.suball[x];.stpps.subfiltered[x;y]]
 };

.u.pub:.stpps.pub

.ps.loaded:1b;
.ps.publish:.stpps.pub;
.ps.subscribe:.u.sub;
.ps.init:.stpps.init;
.ps.initialise:{.ps.init[tables[]];.ps.initialised:1b};

.ps.subtable:{[tab;syms]
  .z.m.log[`info][`subtable;"Received a subscription to ",$[count tab;tab;"all tables"]," for ",$[count syms;syms;"all syms"]];
  val:.u.sub[`$tab;$[count syms;::;first] `$csv vs syms];
  $[10h~type last val;'last val;val]
 };

.ps.subtablefiltered:{[tab;filters;columns]
  .z.m.log[`info][`subtablefiltered;"Received a subscription to ",$[count tab;tab;"all tables"]," for filters: ",filters," and columns: ",columns];
  val:.u.sub[`$tab;1!enlist `tabname`filters`columns!(`$tab;filters;columns)];
  $[10h~type last val;'last val;val]
 };

.ds.map:{[numseg;sym] sym!(sum each string sym)mod numseg};

.ds.subreq:(`u#`$())!`int$();

.ds.stripe:{[input;skey]
  if[0=count input;:`boolean$()];
  if[0N in val:.ds.subreq input;
    .ds.subreq,:.ds.map[.ds.numseg;distinct input where null val];
    val:.ds.subreq input;
  ];
  skey=val
 };
