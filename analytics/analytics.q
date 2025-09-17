/ library for some common use analytic functions


.anl.ffill:{[arg]
  :$[98h=type arg;.anl.filltable[arg];
    99h=type arg;.anl.filldict[arg];
   '"Input parameter must be a dictionary with keys-table, keycols, by or a table to fill "]
   };


/ fill whole table, straight copy of previous values
.anl.filltable:{[t] :fills t;};

.anl.filldict:{[d] 
   / fill table based on provided criterion, by and keycols
    table:d[`table];
    headers:cols table;   
    kcols:d[`keycols],();
    if[2<count key d; 
       :![table;();(enlist d`by)!(enlist d`by);kcols!((^\;) each kcols)]];
     / q-sql:update fills kcols by col from table
    if[`keycols in key d;
       :![table;();0b;kcols!((^\;) each kcols)]];
     / q-sql: update fills keycols1 [,fills keycols2...] from table
    if[`by in key d;          
       :![table;();(enlist d`by)!(enlist d`by);hd!((^\;) each hd:headers where (any null table@) each headers)]];
     / q-sql:update fills null_cols by col from table
     };
    

.anl.ffillzero:{[d]
   / replace zeros in specified columns with previous values
    d[`table]:@[d[`table];d[`keycols];{?[0=x;0n;x]}];
    :.anl.filldict[d];
    };
