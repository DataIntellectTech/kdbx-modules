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
    trackperf[id;status;now]];
    / Otherwise just log it as an addfail - the result set is too big
    trackperf[id;`fail;cp[]]];
  / Return the result	
  res};

// Drop some ids from the cache
drop:{[ids]
	ids,:();
	delete from `cache where id in ids;
	`results : ids _ `results;
	}
	
// evict some items from the cache - need to clear enough space for the new item
// evict the least recently accessed items which make up the total size
// feel free to write a more intelligent cache eviction policy !
evict:{[reqsize;currenttime]
	r:select from 
		(update totalsize:sums size from `lastaccess xasc select lastaccess,id,size from cache)
	where prev[totalsize]<reqsize;
	drop[r`id];
	trackperf[r`id;`evict;currenttime];
	}



trackperf:{[id;status;currenttime] `perf insert ((count id)#currenttime;id;(count id)#status)};


// check the cache to see if a function exists with a young enough result set
execute:{[func;age]
	// check for a value in the cache which we can use
	$[count r:select id,lastrun from .cache.cache where .cache.funcs[id]~\:enlist func;
		// There is a value in the cache.
		[r:first r;
		// We need to check the age - if the specified age is greater than the actual age, return it
		// else delete it
  		$[age > (now:.proc.cp[]) - r`lastrun;
			// update the cache stats, return the cached result
		 	[update lastaccess:now from `.cache.cache where id=r`id;
			 trackperf[r`id;`hit;now];
			 first results[r`id]];
			// value found, but too old - re-run it under the same id
			[drop[r`id];
			 add[func;r`id;`rerun]]]];
		// it's not in the cache, so add it
		add[func;getid[];`add]]}

// get the cache performance
getperf:{update function:.cache.funcs[id] from .cache.perf}

