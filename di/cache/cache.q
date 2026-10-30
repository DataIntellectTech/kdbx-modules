/ cache function results and return them while they are fresh enough

/ the maximum size of the cache in MB
maxsize:10;

/ the maximum size of any individual result set in MB
maxindividual:50;

/ function to change default max individual value
setmaxindiv:{.z.m.maxindividual:x;.z.m.maxindividual:.z.m.maxsize&.z.m.maxindividual}

/ function to change default max size value
setmaxsize:{.z.m.maxsize:x;.z.m.maxindividual:.z.m.maxsize&.z.m.maxindividual}

/ make sure the maxindividual isn't bigger than maxsize
maxindividual:maxsize&maxindividual;

/ mb conversion factor
MB:2 xexp 20;

/ a table to store the cache values in memory
cache:([id:`u#`long$()] lastrun:`timestamp$();lastaccess:`timestamp$();size:`long$());

/ a dictionary of the functions
.z.M.funcs set (`u#`long$())!();

/ the results of the functions
results:(`u#`long$())!();

/ table to track the cache performance
perf:([]time:`timestamp$();id:`long$();status:`symbol$());

id:0j;
getid:{:id+::1};

/ add to cache
add:{[function;id;status]
  / errors propagate to the caller
  res:value function;
  if[(maxindividual*MB)<=size:-22!res;
    / log it as an addfail - the result set is too big
    trackperf[id;`fail;.z.p];
    :res;
  ];
  / check if we need more space to store this item
  now:.z.p;
  if[0>requiredsize:(maxsize*MB) - size+sum exec size from cache;
    evict[neg requiredsize;now];
  ];
  / insert to the cache table
  .z.M.cache upsert (id;now;now;size);
  / and insert to the function and results dictionary
  funcs[id]:enlist function;
  results[id]:enlist res;
  / update the performance
  trackperf[id;status;now];
  / return the result
  res};

/ drop some ids from the cache
drop:{[ids]
  ids,:();
  delete from .z.M.cache where id in ids;
  results:: ids _ results;
 };

/ evict the least recently accessed items until reqsize is freed
evict:{[reqsize;currenttime]
  r:select 
    from
      (update totalsize:sums size from `lastaccess xasc select lastaccess,id,size from cache)
    where 
      prev[totalsize]<reqsize;
  drop[r`id];
  trackperf[r`id;.z.M.evict;currenttime];
 };
  
trackperf:{[id;status;currenttime] .z.M.perf insert ((count id)#currenttime;id;(count id)#status)};

/ check the cache to see if a function exists with a young enough result set
execute:{[func;age]
  / check for a value in the cache which we can use
  $[count r:select id,lastrun from cache where .z.M.funcs[id]~\:enlist func;
    / cached: return it if younger than age, else re-run
    [r:first r;
    $[age > (now:.z.p) - r`lastrun;
      / update the cache stats, return the cached result
      [update lastaccess:now from .z.M.cache where id=r`id;
      trackperf[r`id;`hit;now];
      first results[r`id]];
      / value found, but too old - re-run it under the same id
      [drop[r`id];
      add[func;r`id;`rerun]]]];
    / it's not in the cache, so add it
    add[func;getid[];`add]]};

/ get the cache performance
getperf:{update function:funcs[id] from perf}
