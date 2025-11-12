/ Library to provide a mechanism for storing function results in a cache and returning them from the cache if they are available and non stale.

/ return timestamp function
cp:{.z.p};

/ the maximum size of the cache in MB
maxsize:10;

/ the maximum size of any individual result set in MB
maxindividual:50;

/ make sure the maxindividual isn't bigger than maxsize
maxindividual:maxsize&maxindividual;

MB:2 xexp 20;

/ a table to store the cache values in memory
cache:([id:`u#`long$()] lastrun:`timestamp$();lastaccess:`timestamp$();size:`long$());

/ a dictionary of the functions
funcs:(`u#`long$())!();
/ the results of the functions
results:(`u#`long$())!();

/ table to track the cache performance
perf:([]time:`timestamp$();id:`long$();status:`symbol$());

id:0j;
getid:{:id+::1};

/ add to cache
add:{[function;id;status]
  / Don't trap the error here - if it throws an error, we want it to be propagated out
  res:value function;
  $[(maxindividual*MB)>size:-22!res;
    / check if we need more space to store this item
    [now:cp[];
    if[0>requiredsize:(maxsize*MB) - size+sum exec size from cache; evict[neg requiredsize;now]];
    / Insert to the cache table
    `cache upsert (id;now;now;size);
    / and insert to the function and results dictionary
    funcs[id]:enlist function;
    results[id]:enlist res;
    / Update the performance
    trackperf[0N!id;0N!status;0N!now]];
    / Otherwise just log it as an addfail - the result set is too big
    trackperf[id;`fail;cp[]]];
  / Return the result	
  res};

trackperf:{[id;status;currenttime] `perf insert ((count id)#currenttime;id;(count id)#status)};

