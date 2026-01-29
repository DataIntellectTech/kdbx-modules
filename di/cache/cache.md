# Cache

`cache.q` provides an in-memory, parameterized caching mechanism for storing and reusing function results, reducing computation time for repeat calls.

## Configuration Variables

- **`.cache.maxsize`** — Maximum total cache size in MB.
- **`.cache.maxindividual`** — Maximum size in MB allowed for a single cache entry; capped at `maxsize`.
- **`MB`** — Defines one megabyte as `2 * xexp 20`.

- Use setmaxindiv and setmaxsize functions to change the default values.
- Change the maxsize variable first if both maxsize and maxindividual are changing so that if maxindividual increases past the old
  max size it doesn't get capped at old maxsize. 

- Default values for maxsize and maxindividual are set as 10 and 50 respectively
- These can be changed using setmaxsize and setmaxindiv functions by using a single input in each with desired values.

## Core Structures

- **`cache`** (table) — Tracks cache entries:
  - `id` (long)
  - `lastrun`, `lastaccess` (timestamps)
  - `size` (bytes)
- **`funcs`** (dict) — Maps `id` to the cached function.
- **`results`** (dict) — Maps `id` to the resulting data.
- **`perf`** (table) — Logs cache performance with columns:
  - `time` (timestamp)
  - `id` (long)
  - `status` (symbol: `add`, `hit`, `fail`, `evict`, `rerun`)

## Main Functions

### `getid`
Generates unique IDs for new cache entries by incrementing a global counter.

### `add`
Takes parameters `[function; id; status]` and:
1. Executes `function` via `value`.
2. If result size ≤ `.cache.maxindividual * MB`, ensures enough space:
   - Calculates required space and evicts older entries as needed.
3. Inserts or updates cache table, `funcs`, `results`, logs performance.
4. Otherwise, logs a `fail` and returns the result without caching.

### `drop`
Removes specific cache entries by `id`, updating both the cache table and results dict.

### `evict`
Evicts least-recently-accessed items until required space is freed:
- Sorts by `lastaccess`, sums sizes, iteratively drops entries.
- Logs `evict` in `perf`.

### `trackperf`
Logs performance events (`add`, `hit`, `fail`, `evict`, `rerun`) with timestamps into `perf`.

### `execute`
Parameters: `[func; age]`.
1. Looks for matching cache entry by function identity.
2. If found and `age <= now – lastrun`:
   - Updates `lastaccess`, logs a `hit`, returns cached result.
3. If found but stale:
   - Drops entry, logs `rerun`, re-executes via `add`.
4. If not present:
   - Adds a new cache entry via `add`.

### `getperf`
Returns `perf` table with function mappings added for each event entry.

# Cache Example Usage

This example demonstrates how `.cache.execute` works with caching and stale time logic, along with performance tracking using `.cache.getperf[]`.

## Example Steps

### 1. First Execution
The function is run and the result placed in the cache:

```q
q)       \t r:execute[({system"sleep 2"; x+y};1;2);0D00:01]
2023
q)r
3
```

### 2. Second Execution (Cache Hit)
The second time round, the result set is returned immediately from the cache as we are within the stale time value:

```q
q)       \t r1:execute[({system"sleep 2"; x+y};1;2);0D00:01]
0
q)r1
3
```

### 3. Execution After Stale Time (Re-run)
If the time since the last execution is greater than the required stale time, the function is re-run, the cached result is updated, and the result returned:

```q
q)       \t r2:execute[({system"sleep 2"; x+y};1;2);0D00:00]
2008
q)r2
3
```

### 4. Cache Performance Tracking
The cache performance is tracked using `.cache.getperf[]`:

```q
q).cache.getperf[]
time                          id status function
------------------------------------------------------------------
2013.11.06D12:41:53.103508000 2  add    {system"sleep 2"; x+y} 1 2
2013.11.06D12:42:01.647731000 2  hit    {system"sleep 2"; x+y} 1 2
2013.11.06D12:42:53.930404000 2  rerun  {system"sleep 2"; x+y} 1 2
```


---

## Cache Table Schema

| Column       | Type       | Description                                      |
|--------------|------------|--------------------------------------------------|
| `id`         | `long`     | Unique identifier for cached entry               |
| `lastrun`    | `timestamp`| When the entry was initially added               |
| `lastaccess` | `timestamp`| When entry was last served from cache            |
| `size`       | `long`     | Byte size of the cached result                   |

## perf Table Schema

| Column  | Type        | Description                                |
|---------|-------------|--------------------------------------------|
| `time`  | `timestamp` | When the cache event occurred              |
| `id`    | `long`      | Corresponding cache entry ID               |
| `status`| `symbol`    | Event type (`add`, `hit`, `fail`, etc.)    |
| `function` (added via `getperf`) | `function` | Cached function for the event |

---

