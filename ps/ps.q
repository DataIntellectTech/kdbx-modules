/ subscription table - no filters
.ps.reqalldict:enlist[`]!();

/ subscription table with filters
.ps.reqfilteredtbl:([]table:`symbol$();handle:`int$();filts:();columns:());

/ get all subscription handles that haven been recorded on tables
.ps.getallhandles:{distinct raze union[value .ps.reqalldict;exec handle from .ps.reqfilteredtbl]}

/ add handle to reqalldict dictionary
.ps.add:{[t] if[not .z.w in .ps.reqalldict[t];.ps.reqalldict[t],:.z.w];}  

.ps.delhandle:{[t;h]
     / remove handle from request-all-data table
     if[t in key .ps.reqalldict; @[`.ps.reqalldict;t;except;h]]
     if[not count .ps.reqalldict[t];.ps.reqalldict _:t];  
      } 

/ remove handle from request-filtered-data table
.ps.delhandlef:{[t;h]delete from `.ps.reqfilteredtbl where table=t, handle=h;}  

.ps.suball:{[table]
    / subscribe to table without filtering i.e. all data from the subscribed table
    m:(); table,:(); 
    if[not all table in .ps.t; 
         errmsg:(`$sv[csv;string  m:table except .ps.t]," not available for subscription.");
         table@:where table in .ps.t]; 
    if[count table; 
     {.ps.delhandle[x;.z.w];
       .ps.delhandlef[x;.z.w];
       .ps.add[x]} each table;
      :((errmsg;(table;.ps.schemas[table]));(table;.ps.schemas[table])) [m~()]];
     :errmsg;
   }
     
.ps.subfiltered:{[table;filters]
    / subscribe to tables with filter (symbols or custom conditions)
    m:();
    $[99h=type filters;
       table:key[filters] first cols filters; table,:()];
    if[not all table in .ps.t; 
         errmsg: (`$sv[csv;string  m:table except .ps.t]," not available for subscription");
         table@:where table in .ps.t]; 
    if[count table; 
      {.ps.delhandlef[x;.z.w];
        .ps.delhandle[x;.z.w];
         val:![11 99h;(.ps.addsymsub;.ps.addfiltered)][abs type y] . (x;y)}[;filters] each table;
      :((errmsg;(table;.ps.schemas[table]));(table;.ps.schemas[table])) [m~()]];
      :errmsg;
    }

.ps.addfiltered:{[table;cond]
    / subscribe to tables with custom conditions
    / if either filters or columns parsing fails, subscription should not be logged as no half query should be created 
    filters:$[all null f:cond[table;`filts];();@[parse;"select from t where ",f;{'"incorrect filters for parsing"}][2]]; 
    columns:$[all null c:cond[table;`columns];();@[parse;"select ",c," from t";{'"incorrect columns for parsing"}][4]];
    @[eval;(?;.ps.schemas[table];filters;0b;columns);{'"incorrect query with filters-",.Q.s1[y],"  columns-",.Q.s1[z]," error-",x}[;filters;columns]];
    `.ps.reqfilteredtbl upsert (table;.z.w;filters;columns);
   }

.ps.addsymsub:{[table;syms] 
    / subscribe to tables with symbols
    filts:enlist enlist (in;`sym;enlist syms);
    @[eval;(?;.ps.schemas[table];filts;0b;());{'"incompatible with table schema:",string[y]," error-",x}[;syms]];
    `.ps.reqfilteredtbl upsert (table;.z.w;filts;());
    };

.ps.closesub:{[h]
    / remove handles upon connection close
    .ps.delhandle[;h] each key[.ps.reqalldict];
     delete from `.ps.reqfilteredtbl where handle=h;
    }

/ define .z.pc, add bespoke actions as needed
.z.pc:{.ps.closesub[x]};

/ broadcast to all subscribers upon end of day, client needs to define endofday function
.ps.endd:{(neg .ps.getallhandles[])@\:(`endofday`);}

/ broadcast to all subscribers upon end of period, client needs to define endofperiod function
.ps.endp:{(neg .ps.getallhandles[])@\:(`endofperiod`);}

/ get table schema
.ps.extractschema:{[table] 0#value table}; 

.ps.subscribe:{[table;filters]   
    / single entry point for subscriptions: uses default list when no table name provided; routes to suball if filters null, otherwise subfiltered
     if[`~table;:.z.s[.ps.t;filters]];
     if[not `~table;
         :$[`~filters;.ps.suball[table];.ps.subfiltered[table;filters]]]
     }

.ps.publish:{[t;x]
    / single entry point for publishing
    if[not count x;:()];
    if[count h:.ps.reqalldict[t];-25!(h;(`upd;t;x))];
    if[count d:select from .ps.reqfilteredtbl where table=t;
       {if[count filtered:eval(?;y;z`filts;0b;z`columns);neg[z`handle](`upd;x;filtered)]}[t;x;] each d;
       ];
     }

.ps.pubclear:{[t]
    / publish tables and clear up the contents
    .ps.publish'[t;value each t,:()];
     @[`.;;0#] each t;
     }     

.ps.substr:{[table;syms]
    / allow non-kdb+ process to subscribe to tables with/without symbols
     res:.ps.subscribe[`$table;$[count syms;`$vs[csv;syms];`]];
     :$[10h~type last res;'last res;res];
   }

.ps.substrf:{[table;filters;columns]
    / allow non-kdb+ process to subscribe to tables with custom conditions
     res:.ps.subscribe[`$table;1!enlist `table`filts`columns!(`$table;filters;columns)]; 
     :$[10h~type last res;'last res;res];
   }
      
/ set .u functions in case they get called
.u.sub:.ps.subscribe;
.u.pub:.ps.publish;

/by default get all tables on top level of STP
.ps.availtables:1b;  

/user-specified list of tables for subscription
.ps.subtables:`$();  

.ps.initialized:0b;

.ps.init:{
    .ps.t:$[.ps.availtables |0=count .ps.subtables;tables `.;.ps.subtables];       
     .ps.schemas:.ps.t!.ps.extractschema each .ps.t; 
     .ps.tabcols:.ps.t!cols each .ps.t;
     if[count .ps.tabcols;.ps.initialized:1b];
     }
