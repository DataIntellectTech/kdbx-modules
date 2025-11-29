ffill:{[arg]
  / forward fills null values in specified columns (or all columns) with the last non-null value, optionally grouped by key columns. The function is the single point of entry for different input types: dictionary or table.
  :$[.Q.qt arg;filltable[arg];
    99h=type arg;filldict[arg];
   '`$"Input parameter must be a dictionary with keys-(table, keycols, by), or a table to fill"];
     }

/ forward fill a column in a table, handle both typed and mixed columns
fillcol: {$[0h=type x; x maxs (til count x)*(0<any each not null each x); fills x]}

/ forward fill all columns in a table
filltable:{[t] ![t;();0b;((),cols[t])!(.z.M.fillcol),/: cols[t],()]}  

filldict:{[d] 
  / fill with dictionary argument
  if[not `table in fkey:key d;'`$"Input table is missing"];
  if[(`keycols in fkey) & `by in fkey;
    :![d`table;();((),d`by)!((),d`by);((),d`keycols)!(.z.M.fillcol),/:((),d`keycols)]];     
  if[`keycols in fkey;
    :![d`table;();0b;((),d`keycols)!(.z.M.fillcol),/: ((),d`keycols)]];
  if[`by in fkey;     
    :![d`table;();(enlist d`by)!(enlist d`by);(cols d`table)!(.z.M.fillcol),/: cols d`table]];
  filltable[d`table];
    }

ffillzero:{[d]
   / forward fills zero values in specified columns or all columns with the last non-zero value, optionally grouped by key columns.
  if[any not `table`keycols in key d;'`$"Input table or key columns are missing"];
  (d`table):@[d`table;d`keycols;{?[0=x;0n;x]}];
   :filldict[d];
    }

intervals:{[d]
  / create time intervals with bespoke increments
  $[99h<> type d; '`$"input should be a dictionary";
     not all `start`end`interval in fkey:key[d];'`$"Input parameter must be a dictionary with at least three keys (an optional key round):\n\t-",sv["\n\t-";string `start`end`interval];
     any not (itype:.Q.ty'[d`start`end`interval`round]) in ("MmuUiIjJhHNnVvDdPptTB");'`$("One or more of inputs are of an invalid type.");
     1<count distinct 2#itype;'`$"interval start and end data type mismatch";
      (not (itype 2) in ("iIjJ")) & (itype 0) in ("MmDd");'`$"interval types should be int/long for date/month intervals"];
        
  istart:d`start;
  iend:d`end;
  istep:d`interval;

 if[(itype 0) in "Pp";
   if[(itype 2) in "Uu";istep:(`long$istep)*60*1000000000];
   if[(itype 2) in "Vv";istep:(`long$istep)*1000000000]];

  adjStart:$[(`round in fkey) & not d`round; 
             istart;
             istep*`long$istart div istep];
  interval:abs[type istart]$adjStart+istep*til 1+ceiling(iend-adjStart)%istep;
  :$[iend<last interval;-1_interval;interval];
    }
 
pivot:{[d]
  / Reorganizes table data by pivoting specified columns into a cross-tabular format with aggregated values 
  $[99h<> type d; '`$"input should be a dictionary";
     not all `table`by`piv`var in fkey:key[d];'`$"Input parameter must be a dictionary with at least four keys (with optional keys f and g):\n\t-",sv["\n\t-";string `table`by`piv`var];
     any not itype:.Q.ty'[d`table`by`piv`var] in (" sS");'`$("One or more of inputs are of an invalid type.")];
     
  if[(any/) not d[`by`piv`var] in cols [d`table];'`$"some columns provided do not exist in the table"];
  
  t:d`table;
  k:(),d`by;
  p:(),d`piv;
  v:(),d`var;
  f:$[`f in fkey;d`f;{[v;P] `$"_" sv' string (v,()) cross P}];
  g:$[`g in fkey;d`g;{[k;c] k,asc c}];
  G:group flip k!(t:.Q.v t)k;
  F:group flip p!t p;

  count[k]!g[k;C]xcols 0!key[G]!flip(C:f[v]P:flip value flip key F)!raze
  {[i;j;k;x;y]
   a:count[x]#x 0N;
   a[y]:x y;
   b:count[x]#0b;
   b[y]:1b;
   c:a i;
   c[k]:first'[a[j]@'where'[b j]];
   c}[I[;0];I J;J:where 1<>count'[I:value G]]/:\:[t v;value F]}

rack:{[d]
  / Creates a cross product (rack) of distinct column values, optionally with time series intervals and/or base table expansion
  $[99h<> type d; '`$"input should be a dictionary";
     not all `table`keycols in fkey:key[d];'`$"Input parameter must be a dictionary with at least two keys (with optional keys base, timeseries, fullexpansion):\n\t-",sv["\n\t-";string `table`keycols]];
  if[any not d[`keycols] in cols [d`table];'`$"some of the key columns provided do not exist in the table"];
  
  tab:d`table;
  keycol:d`keycols;
  fullexp:$[`fullexpansion in fkey;d`fullexpansion;0b];
  rackkeycol:$[fullexp;flip keycol!flip (cross/)  distinct@/:(0!tab)[keycol];flip keycol!(0!tab)[keycol]];
  if[`timeseries in fkey; 
       timeinterval:flip (enlist `interval)!enlist intervals[d`timeseries]; 
       :$[`base in fkey; (cross/)(d`base;rackkeycol;timeinterval); (cross/)(rackkeycol;timeinterval)]];
  :$[`base in fkey; (cross/)(d`base;rackkeycol); rackkeycol];       
   }
            
            
            
           
