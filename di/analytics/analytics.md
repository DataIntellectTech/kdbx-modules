# Analytics Functions Library

A set of analytical utilities designed to streamline and make common data manipulation operations more efficient in kdb+/q.

The library provides specialized functions for handling typical analytical workflows, including forward filling missing values, creating custom time intervals, pivoting tables, and generating cross-product expansions. Each function accepts dictionary parameters or a table for flexible configuration and includes robust error handling with informative messages.

---

## Overview

- **`ffill`** – Forward fill missing values within columns (optionally by group).
- **`ffillzero`** – Treat zeros as missing and forward fill with the last non-zero value.
- **`intervals`** – Generate custom time/value intervals with configurable step and rounding.
- **`pivot`** – Transform tables into cross-tab (wide) format using a pivot column.
- **`rack`** – Build cross products of key columns, optionally with time intervals and base tables.

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

Generates custom time or numeric interval sequences with configurable start, end, and increment parameters. Supports multiple temporal data types and optional rounding.

**Parameters**
- Dictionary containing:
  - `start`: Beginning of interval range (**required**)
  - `end`: End of interval range (**required**)
  - `interval`: Step size between intervals (**required**)
  - `round`: Boolean flag for rounding start time to nearest interval (optional, default: `1b`)

**Behaviour**
- Supports multiple data types: `minute`, `second`, `time`, `timespan`, `timestamp`, `month`, `date`, `int`, `long`, `real`, `float`, `short`, `byte`.
- `start` and `end` must have matching data types.
- When `round` is false or omitted, `start` is rounded down to the nearest interval boundary.
- The final interval is excluded if it exceeds the `end` parameter.

**Examples**
```q
// Generate 15-minute intervals for trading day
intervals[`start`end`interval!(09:30:00.000; 16:00:00.000; 00:15:00.000)]

// Daily intervals without rounding
intervals[`start`end`interval`round!(2024.01.01; 2024.12.31; 1D; 0b)]

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
```
