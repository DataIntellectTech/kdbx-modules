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

/ ============================================================
/ time-series simplification
/ ============================================================

/ ramer-douglas-peucker line simplification, following "Dynamically shrinking big data using
/ timeseries database kdb+" by Sean Keevey and Kevin Smyth (https://code.kx.com/q/wp/ts-shrink/).
/ a chord is drawn between the first and last points of a series and the point furthest from
/ that chord is measured: if it sits further away than the caller's tolerance it is kept as a
/ breakpoint and the two halves either side of it are simplified the same way, otherwise every
/ point between the endpoints is discarded. what survives is the small set of points that carry
/ the shape of the series - spikes and turning points are preserved while flat runs collapse.

/ the x axis may be numeric or temporal - short, int, long, real, float, timestamp, month,
/ date, timespan, minute, second, time. the y axis must be numeric
xaxistypes:5 6 7 8 9 12 13 14 16 17 18 19h;
yaxistypes:5 6 7 8 9h;

checktolerance:{[tolerance]
  / a null or negative tolerance would keep nothing sensible and, worse, would let a segment
  / split on a point it has already kept - reject it before either kernel runs
  if[not (type tolerance) in neg yaxistypes;'`$"tolerance must be a numeric atom"];
  if[(null tolerance) or 0>tolerance;'`$"tolerance must be a non-negative number"];
  };

pdist:{[x1;y1;x2;y2;px;py]
  / perpendicular distance from each point (px;py) to the line through (x1;y1) and (x2;y2)
  / a chord with no x extent has no gradient, so fall back to distance from the line x=x1
  if[x1=x2;:abs px-x1];
  slope:(y2-y1)%x2-x1;
  intercept:y1-slope*x1;
  :abs((slope*px)+intercept-py)%sqrt 1f+slope*slope;
  };

/ every index in the segment running from point s to point e inclusive
segpoints:{[s;e] s+til 1+e-s};

segdist:{[px;py;idx]
  / distance from every point of the segment spanned by idx to that segment's own chord.
  / both endpoints lie on the chord by construction, so pin them to zero rather than leave
  / them to floating-point noise: that guarantees the furthest point is an interior one and
  / so every split strictly shrinks the segment
  d:pdist[px first idx;py first idx;px last idx;py last idx;px idx;py idx];
  :@[d;0,-1+count d;:;0f];
  };

furthest:{[px;py;s;e]
  / index of the point furthest from the chord joining points s and e, and its distance
  d:segdist[px;py;segpoints[s;e]];
  :(s+first where d=max d;max d);
  };

preppoints:{[px;py]
  / casts both axes to float for the distance arithmetic. x is rebased on its first value
  / before the cast: perpendicular distance is unchanged by that shift, and it preserves
  / nanosecond resolution on timestamps, which a direct cast to float would round away
  :("f"$px-first px;"f"$py);
  };

recurse:{[tolerance;px;py;s;e]
  / recursive kernel - the indices kept from the segment between points s and e
  brk:furthest[px;py;s;e];
  :$[tolerance<brk 1;
    (.z.s[tolerance;px;py;s;brk 0]),1_.z.s[tolerance;px;py;brk 0;e];
    s,e];
  };

rdprecur:{[tolerance;px;py]
  / recursive ramer-douglas-peucker. returns the ascending indices of the points worth
  / keeping, always including the first and last point of the series.
  / marginally faster than rdpiter, but recursion depth is driven by the data, so the paper
  / reports stack exhaustion on highly volatile series at a low tolerance - use rdpiter there
  checktolerance[tolerance];
  if[3>count px;:til count px];
  pts:preppoints[px;py];
  :recurse[tolerance;pts 0;pts 1;0;-1+count px];
  };

/ the two segments a parent segment splits into at breakpoint b
bisect:{[seg;b] (seg[0],b;b,seg 1)};

/ every point of the given segments bar their endpoints - the points a retired segment drops
interiors:{[segs] `long$raze {1_-1_segpoints . x} each segs};

iterate:{[tolerance;px;py;state]
  / one pass of the iterative kernel. every pending segment is measured against its chord and
  / is either split at its furthest point or, if that point is within tolerance, retired -
  / dropping all of its interior points. state is (pending segments;keep flags)
  pending:state 0;
  if[not count pending;:state];
  brk:flip furthest[px;py] ./: pending;
  split:tolerance<brk 1;
  :(raze bisect'[pending where split;(brk 0) where split];
    @[state 1;interiors pending where not split;:;0b]);
  };

rdpiter:{[tolerance;px;py]
  / iterative ramer-douglas-peucker. returns exactly the same indices as rdprecur, but holds
  / the segments still to examine in an explicit queue rather than on the stack, so it is safe
  / for any combination of series length, volatility and tolerance.
  / the paper walks that queue one segment per pass; splitting every pending segment in a
  / single pass instead cuts the pass count from one per retained point to the depth of the
  / split tree, which brings the iterative kernel back within touching distance of recursion
  checktolerance[tolerance];
  if[3>count px;:til count px];
  pts:preppoints[px;py];
  :where last iterate[tolerance;pts 0;pts 1]/[(enlist 0,-1+count px;count[px]#1b)];
  };

/ simplification kernels selectable through shrink's method argument
kernels:`recursive`iterative!(rdprecur;rdpiter);

checkorder:{[px]
  / each point is measured against the chord joining its segment endpoints, which only
  / describes the series if the points arrive in x order
  if[any 0>1_deltas "f"$px-first px;
    '`$"xcol must be non-decreasing within each series - sort the table on xcol first"];
  };

shrinkseries:{[kernel;tolerance;px;py]
  / retained row indices for a single ordered series
  checkorder[px];
  :kernel[tolerance;px;py];
  };

shrinkgroups:{[kernel;tolerance;px;py;grp]
  / simplify each group of row indices independently, returning the retained rows in the
  / order they appear in the source table
  :`long$asc raze grp@'shrinkseries[kernel;tolerance]'[px@grp;py@grp];
  };

shrink:{[d]
  / discards the points of a series that lie within tolerance of the line joining the points
  / bracketing them, returning the input table restricted to the rows worth keeping.
  / rows must already be ordered by xcol, within each by group where by is supplied
  $[99h<>type d;'`$"input should be a dictionary";
     not all `table`xcol`ycol`tolerance in fkey:key[d];'`$"Input parameter must be a dictionary with at least four keys (with optional keys by and method):\n\t-",sv["\n\t-";string `table`xcol`ycol`tolerance];
     not .Q.qt d`table;'`$"table must be a table";
     any not -11h=type each d`xcol`ycol;'`$"xcol and ycol must each name a single column";
     not (method:$[`method in fkey;d`method;`iterative]) in key kernels;'`$"method must be one of:\n\t-",sv["\n\t-";string key kernels]];

  checktolerance[d`tolerance];
  / keyed tables are simplified on their unkeyed form and returned unkeyed
  t:0!d`table;
  bycols:$[`by in fkey;(),d`by;`symbol$()];
  if[count missing:(d[`xcol],d[`ycol],bycols) except cols t;
    '`$"some columns provided do not exist in the table: ",sv[", ";string missing]];

  px:t d`xcol;
  py:t d`ycol;
  if[not (abs type px) in xaxistypes;'`$"xcol must be a numeric or temporal column"];
  if[not (abs type py) in yaxistypes;'`$"ycol must be a numeric column"];
  if[any raze null (px;py);'`$"xcol and ycol must not contain nulls - remove them before shrinking"];

  :t $[count bycols;
    shrinkgroups[kernels method;d`tolerance;px;py;value group flip bycols!t bycols];
    shrinkseries[kernels method;d`tolerance;px;py]];
  };
