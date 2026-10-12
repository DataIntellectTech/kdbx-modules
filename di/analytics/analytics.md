# Analytics Functions Library

A set of analytical utilities designed to streamline and make common data manipulation operations more efficient in kdb+/q.

The library provides specialized functions for handling typical analytical workflows, including forward filling missing values, creating custom time intervals, pivoting tables, generating cross-product expansions, and simplifying time series down to the points that carry their shape. Each function accepts dictionary parameters or a table for flexible configuration and includes robust error handling with informative messages.

---

## Overview

- **`ffill`** – Forward fill missing values within columns (optionally by group).
- **`ffillzero`** – Treat zeros as missing and forward fill with the last non-zero value.
- **`intervals`** – Generate custom time/value intervals with configurable step and rounding.
- **`pivot`** – Transform tables into cross-tab (wide) format using a pivot column.
- **`rack`** – Build cross products of key columns, optionally with time intervals and base tables.
- **`shrink`** – Reduce a time series to the points that carry its shape (Ramer-Douglas-Peucker).
- **`rdprecur`** / **`rdpiter`** – The recursive and iterative simplification kernels behind `shrink`.

---

## Functions

### ⚙️`ffill`

**Description**  

Forward fills null values in specified columns with the most recent non-null observation. Supports both table-level operations and granular control through dictionary parameters.

**Parameters**
- Input can be either a table or a dictionary.
- when argument is table, forward fill the whole table (same as calling fills).
- When using dictionary format:
  - `table`: The table to process (**required**)
  - `keycols`: Column(s) to fill (optional – defaults to all columns)
  - `by`: Grouping column(s) for segmented filling (optional)

**Behaviour**
- Processes columns independently, preserving data types.
- Handles both typed columns and mixed-type columns.
- When `by` is specified, filling occurs within each group.
- Combines `by` and `keycols` for targeted group-wise filling.

**Examples**
```q
// Fill all columns in a table
filledTable: ffill[table]

// Fill specific columns
ffill[`table`keycols!(myTable; `ask`bid)]

// Group-wise filling by symbol
ffill[`table`by`keycols!(myTable; `sym; `price`size)]

// Combined grouping and column selection
ffill[`table`by`keycols!(myTable; `sym; `ask`bid)]
```

---

<br>


### ⚙️ `ffillzero`

**Description**  

Extends forward-fill functionality to handle zero values by treating them as missing data points before applying the fill operation.

**Parameters**
- Dictionary with:
  - `table`: Source table (**required**)
  - `keycols`: Columns where zeros should be filled (**required**)
  - `by`: Optional grouping column(s)

**Behaviour**
1. Converts zero values to null in specified columns.  
2. Applies `ffill` logic.  
3. Returns a table with zeros replaced by previous non-zero values.

**Examples**
```q
// Replace zeros with last non-zero value
ffillzero[`table`keycols!(priceData; `bid`ask)]

// Group-wise zero filling
ffillzero[`table`by`keycols!(priceData; `sym; `price)]
```

---
<br>

### ⚙️ `intervals`

**Description**  

Generates custom time or numeric interval sequences with configurable start, end, and increment parameters. Supports multiple temporal data types with optional rounding to interval boundaries.

**Parameters**
- Dictionary containing:
  - `start`: Beginning of interval range (**required**)
  - `end`: End of interval range (**required**)
  - `interval`: Step size between successive intervals (**required**)
  - `round`: Boolean flag for rounding start  to nearest interval boundary (optional, default: `1b`)

**Behaviour**
- Supports multiple data types: `minute`, `second`, `time`, `timespan`, `timestamp`, `month`, `date`, `int`, `long`, `short`, `byte`.
- `start` and `end` must have matching data types.
- When `round` is false or omitted, `start` is rounded down to the nearest interval boundary.
- The sequence excludes any final interval that would exceed `end`.
- Date/month intervals: `interval` must be int or long (fractional dates/months not permitted)
- Timestamp intervals: interval accepts minute, second, timespan, int, or long. When using numeric types (int/long), values represent nanoseconds—use caution to prevent overflow.

**Examples**
```q
// Generate 15-minute intervals for trading day
intervals[`start`end`interval!(09:30:00.000; 16:00:00.000; 00:15:00.000)]

// Daily intervals without rounding
intervals[`start`end`interval`round!(2024.01.01; 2024.12.31; 1; 0b)]

// Hourly timestamps with automatic rounding
intervals[`start`end`interval!(2024.01.01D09:00:00; 2024.01.01D17:00:00; 01:00:00)]
```

---
<br>

###  ⚙️`pivot`

**Description**  

Reorganizes tabular data by transforming unique values from a pivot column into individual columns, with aggregated values at intersections. Creates a cross-tabular representation suitable for reporting and analysis.

**Parameters**
- Dictionary with:
  - `table`: Source table (**required**)
  - `by`: Row grouping column(s) (**required**)
  - `piv`: Column whose distinct values become new columns (**required**)
  - `var`: Value column(s) to aggregate (**required**)
  - `f`: Column naming function (optional – defaults to concatenation with underscore)
  - `g`: Column ordering function (optional – defaults to keeping `by` columns followed by sorted pivot columns)

**Behaviour**
- Groups data by `by` columns to form rows.
- Groups by `piv` columns to determine new column structure.
- Aggregates `var` values at each intersection.
- Applies naming and ordering functions (`f`, `g`) to the final result.

**Examples**
```q
// Basic pivot: levels become columns
pivot[`table`by`piv`var!(quotes; `date`sym`time; `level; `price)]

// Multiple aggregation columns
pivot[`table`by`piv`var!(trades; `date`sym; `exchange; `price`volume)]

// Custom column naming
pivot[`table`by`piv`var`f!(data; `date; `category; `value; {[v;P] `$"_" sv' string v,'P})]
```

---
<br>

### ⚙️`rack`

**Description**  

Constructs a cross product of distinct column values, creating all possible combinations. Optionally integrates time series intervals and/or base table expansion for comprehensive data frameworks.

**Parameters**
- Dictionary containing:
  - `table`: Source table (**required**)
  - `keycols`: Columns to cross-product (**required**)
  - `base`: Additional table to cross with result (optional)
  - `timeseries`: Dictionary for interval generation (optional, uses `intervals` function)
  - `fullexpansion`: Boolean for complete Cartesian product of key columns (optional, default: `0b`)

**Behaviour**
- Standard mode preserves existing row-wise combinations in `keycols`.
- Full expansion mode (`fullexpansion` = `1b`) generates all possible combinations across `keycols`.
- Can integrate with time series intervals for temporal expansion.
- Supports base table cross-product for additional dimensionality.

**Examples**
```q
// Generate all symbol combinations from table
rack[`table`keycols`fullexpansion!(trades; `sym; 1b)]

// Rack with time intervals
rack[`table`keycols`timeseries!(trades; `sym; `start`end`interval!(09:30; 16:00; 00:15))]

// Combine base table with rack and intervals
rack[`table`keycols`base`timeseries!(trades; `sym; baseData; intervalDict)]

// Preserve existing combinations without expansion
rack[`table`keycols!(quotes; `sym`exchange)]
```

---
<br>

### ⚙️`shrink`

**Description**

Reduces a time series to the handful of points that carry its shape, discarding those that add
nothing. Spikes, turning points and trend changes survive; flat or near-linear runs collapse to
their endpoints. Unlike bucketing, nothing is averaged or moved — every returned row is a real row
from the source table, so neither the time nor the value domain is distorted.

This is the Ramer-Douglas-Peucker algorithm described in
[Dynamically shrinking big data using timeseries database kdb+](https://code.kx.com/q/wp/ts-shrink/)
— see [References](#references).

**Parameters**
- Dictionary containing:
  - `table`: Source table (**required**)
  - `xcol`: Name of the x-axis column — one numeric or temporal column (**required**)
  - `ycol`: Name of the y-axis column — one numeric column (**required**)
  - `tolerance`: Non-negative numeric atom; how far a point may sit from the line through its
    neighbours before it is worth keeping (**required**)
  - `by`: Grouping column(s) — each series is simplified independently (optional)
  - `method`: `` `recursive`` or `` `iterative`` (optional, default: `` `iterative``)

**Behaviour**
1. Draw a chord between the first and last points of the series.
2. Find the point furthest from that chord.
3. If it is further away than `tolerance`, keep it as a breakpoint and repeat on the two halves
   either side of it; otherwise discard every point between the endpoints.

- The first and last points of each series are always retained.
- The guarantee this gives: every discarded point lies within `tolerance` of the straight line
  joining the two retained points that bracket it.
- Rows must already be ordered by `xcol` — within each `by` group where `by` is supplied. Out of
  order input is rejected rather than silently simplified against meaningless chords.
- `xcol` and `ycol` must not contain nulls; filter or forward fill (see `ffill`) beforehand.
- All columns are carried through untouched — `shrink` selects rows, it does not project columns.
- With `by`, groups are simplified independently and the retained rows are returned in the order
  they appear in the source table, not grouped.
- Keyed tables are simplified on their unkeyed form and returned unkeyed.

**Examples**
```q
// Thin a day of prices down to its shape, to a tolerance of half a tick
shrink[`table`xcol`ycol`tolerance!(trades; `time; `price; 0.005)]

// Simplify each symbol separately
shrink[`table`xcol`ycol`tolerance`by!(trades; `time; `price; 0.005; `sym)]

// Use the recursive kernel instead of the default iterative one
shrink[`table`xcol`ycol`tolerance`method!(trades; `time; `price; 0.005; `recursive)]

// Works on any ordered numeric axis, not just time
shrink[`table`xcol`ycol`tolerance!(curve; `strike; `vol; 0.001)]
```

---
<br>

### ⚙️`rdprecur` / `rdpiter`

**Description**

The two simplification kernels that `shrink` dispatches to, exposed for callers working with plain
vectors rather than a table. Both take the same arguments and return exactly the same answer — they
differ only in how the work is sequenced.

**Parameters**

Called positionally as `[tolerance; x; y]`:
- `tolerance`: Non-negative numeric atom (**required**)
- `x`: x-axis vector — numeric or temporal, non-decreasing (**required**)
- `y`: y-axis vector — numeric, same length as `x` (**required**)

**Behaviour**
- Returns the **indices** of the retained points, in ascending order — not the points themselves.
  Indices compose better than values: they can be used to select from any parallel vector, or from
  the whole table, which is what `shrink` does.
- A series of fewer than three points is returned whole.
- Neither kernel checks that `x` is ordered; `shrink` does that before it calls them.

**Examples**
```q
// Indices of the points worth keeping
keep: rdpiter[0.005; trades`time; trades`price]

// Use them to select from the source table
trades keep

// The two kernels agree, by construction
rdprecur[0.005; x; y] ~ rdpiter[0.005; x; y]    / 1b
```

---
<br>

### Choosing a tolerance

The distance being measured is *perpendicular* to the chord, so it mixes the two axes and its
meaning depends on their relative scale:

- When `x` is a timestamp, its magnitude dwarfs any realistic `y`. The chord is effectively flat in
  the rescaled space, so the perpendicular distance is the vertical gap between the point and the
  chord — and `tolerance` reads directly in `y` units (price, volume, basis points).
- When the axes are comparable — a row number against a price, say — the distance is a genuine
  perpendicular one and `tolerance` is a distance in that plane.

A tolerance of `0` removes only points that are exactly redundant (collinear runs, repeated values).
A tolerance wider than the whole series collapses it to its two endpoints. In between, start from a
small fraction of the `y` range — a tick, a basis point — and adjust against the reduction achieved.

### Recursive or iterative?

| | `rdprecur` | `rdpiter` |
|---|---|---|
| Work queue | q's call stack | an explicit list of pending segments, walked with converge (`/`) |
| Depth risk | recursion depth is driven by the data; the paper reports stack exhaustion on volatile series at a low tolerance | none |
| Speed | marginally faster | within a few percent |

On a 20,000-point random walk at `tolerance` 0.05 (18% of points discarded), the two kernels ran in
roughly 106 ms and 112 ms respectively. The paper's own iterative implementation walks its queue one
segment per pass, which costs it about 3x against recursion; splitting *every* pending segment in a
single pass instead reduces the number of passes from one per retained point to the depth of the
split tree, which is what closes the gap here.

Because the difference is small and the failure mode of deep recursion is a hard `'stack` error,
`shrink` defaults to `` `iterative``. Reach for `` `recursive`` when the series is known to be
well behaved and the last few percent matter.

---
<br>

## Error Handling

The functions implement comprehensive validation with descriptive error messages:
- **Type validation** – Ensures input parameters match expected types.
- **Structure validation** – Verifies the dictionary contains required keys.
- **Column validation** – Confirms specified columns exist in target tables.
- **Data type consistency** – Validates matching types across related parameters.

**Example error messages**
```q
'Input parameter must be a dictionary with keys-(table, keycols, by), or a table to fill
'Input parameter must be a dictionary with at least three keys (an optional key round):-start-end-interval
'some columns provided do not exist in the table
'interval start and end data type mismatch
'tolerance must be a non-negative number
'xcol must be non-decreasing within each series - sort the table on xcol first
'xcol and ycol must not contain nulls - remove them before shrinking
```

---

## References

The time-series simplification functions (`shrink`, `rdprecur`, `rdpiter`) implement the
Ramer-Douglas-Peucker approach set out in:

> Sean Keevey and Kevin Smyth, *Dynamically shrinking big data using timeseries database kdb+*,
> KX whitepaper — <https://code.kx.com/q/wp/ts-shrink/>

The paper supplies the algorithm, the perpendicular-distance formulation and the recursive /
iterative split. This implementation differs from the listings in it in three respects, all noted
in the code:

- the kernels return **indices** rather than `(x;y)` pairs, so every column of the source table can
  be carried through;
- the x axis is **rebased on its first value** before the distance arithmetic, which keeps full
  resolution for nanosecond timestamps;
- the endpoints of each segment have their distance **pinned to zero** rather than left to
  floating-point noise. Without this a segment can pick one of its own endpoints as the breakpoint
  and fail to shrink, which recurses forever at a tolerance of `0`.
