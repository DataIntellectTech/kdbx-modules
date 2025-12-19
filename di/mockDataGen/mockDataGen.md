# Mock Data Generator

This module is used for generating realistic mock datasets. This also allows to generate additional datasets and works in batch. Module consists of four main functions that generates realistic mock datasets based on the following inputs from the user:

-sym/instrument: the symbol to generate for
-date : the date
-start time and end time : to allow generation within a range
-rowcount : the number of rows of data to generate
-start price: the starting price of the instrument/sym
-level: If level 1, generates data for trades and quotes tables. If level 2, generates data for depth along with trades and quotes tables

## Example
Below is an example of loading the module into a session and viewing the functions present in the module.

```q
// Loading the module into a session
mockData: use `di.mockDataGen

// View dictionary of functions
mockData
```

## Overview

- **`mockDataOne`** – Generates mock data for single instrument on a given date.
- **`mockData`** – Generates mock data for multiple instruments on a given date.
- **`mockDataR`** – Generates mock data for multiple instruments in a given date range.
- **`mockHdb`** – writes the data down to a specified HDB directory and sets the attribute to the date partitions.


## Functions

### ⚙️`mockDataOne`

Generates mock data for the given single instrument on the given date along with the following given parameters.

**Parameters**
- `sym`: Instrument/symbol for which the data is generated.
- `date`: Trading date for which the data is generated.
- `startTime`: Market open time or the starting time from which data generation begins.
- `endTime`: Market close time or the ending time up to which data is generated.
- `rowCnt`: Number of rows to generate the data for. Also equals to the number of rows for trade table.
- `startPx`: Starting price of the instrument of type float.
- `level`: Controls the depth of data generation:
  - `1`: Generates trades and quotes tables.
  - `2`: Generates trades, quotes, and depth tables.

**Examples**

```q
// Function signature:
mockDataOne[sym; date; startTime; endTime; rowCnt; startPx; level]

// Loading the module into a session
md: use `di.mockDataGen

// Level 1: Generate trades and quotes only
// for the AAPL instrument on a given trading day:
md.mockDataOne[`AAPL; 2025.01.10; 09:30:00.00; 17:30:00.00; 3000; 22.35; 1]

// Level 2: Generate trades, quotes, and depth
// for the AAPL instrument on a given trading day:
md.mockDataOne[`AAPL; 2025.01.10; 09:30; 16:00; 300; 22.35; 2]

// to view the data
.m.di.0mockDataGen.trades

time                          sym  src price size 
--------------------------------------------------
2025.01.10D09:32:15.619000000 AAPL O   22.34 1283 
2025.01.10D09:32:46.924000000 AAPL O   22.38 8105 
2025.01.10D09:32:48.758000000 AAPL O   22.34 263  
2025.01.10D09:33:30.234000000 AAPL N   22.31 474  
2025.01.10D09:34:04.825000000 AAPL N   22.36 131  
2025.01.10D09:34:15.211000000 AAPL O   22.33 8281 

.m.di.0mockDataGen.quotes

time                          sym  src bid   ask   bsize asize
--------------------------------------------------------------
2025.01.10D09:30:17.136000000 AAPL L   22.34 22.35 7200  4200 
2025.01.10D09:30:41.169000000 AAPL L   22.33 22.36 12000 7800 
2025.01.10D09:30:48.010000000 AAPL O   22.31 22.35 8400  6000 
2025.01.10D09:30:52.784000000 AAPL L   22.32 22.35 12000 1800 
2025.01.10D09:30:55.239000000 AAPL N   22.32 22.37 5400  9000 
2025.01.10D09:30:55.556000000 AAPL O   22.35 22.38 3000  9600 

.m.di.0mockDataGen.depth

time                          sym  bid1  bsize1 bid2  bsize2 bid3  bsize3 bid4  bsize4 bid5  bsize5 ask1  asize1 ask2  asize2 ask3  asize3 ask4  asize4 ask5  asize5
--------------------------------------------------------------------------------------------------------------------------------------------------------------------
2025.01.10D09:30:02.340000000 AAPL 22.34 3600   22.33 4800   22.32 9600   22.31 6000   22.3  4800   22.35 6600   22.36 7800   22.37 8400   22.38 7800   22.39 8400  
2025.01.10D09:30:05.040000000 AAPL 22.33 7200   22.32 9600   22.31 7800   22.3  13200  22.29 10800  22.36 4800   22.37 7800   22.38 6000   22.39 5400   22.4  7200  
2025.01.10D09:30:05.464000000 AAPL 22.31 9000   22.3  9600   22.29 12600  22.28 10200  22.27 19800  22.35 9600   22.36 10200  22.37 11400  22.38 10800  22.39 12600 
2025.01.10D09:30:11.246000000 AAPL 22.32 9000   22.31 12000  22.3  14400  22.29 10200  22.28 19200  22.35 2400   22.36 3000   22.37 4200   22.38 3000   22.39 4800  
2025.01.10D09:30:14.423000000 AAPL 22.32 2400   22.31 3600   22.3  7200   22.29 11400  22.28 9000   22.37 3600   22.38 4200   22.39 4800   22.4  4200   22.41 5400  
2025.01.10D09:30:19.556000000 AAPL 22.35 10200  22.34 11400  22.33 12600  22.32 16800  22.31 19800  22.38 11400  22.39 13200  22.4  12600  22.41 13800  22.42 13200 

```

### ⚙️`mockData`

Generates mock data for the given multiple instruments on the given date along with the following given parameters.

**Parameters**
- `syms`: Instruments/symbols for which the data is generated.
- `date`: Trading date for which the data is generated.
- `startTime`: Market open time or the starting time from which data generation begins.
- `endTime`: Market close time or the ending time up to which data is generated.
- `rowCnts`: Number of rows to generate the data for each syms. This should be passed as a dictionary, for example: `AAPL`MSFT`META!300 500 200 
- `startPxs`: Starting price of the given instruments of type float. Should be passed as a dictionary, for example: `AAPL`MSFT`META!22.33 38.34 29.43
- `level`: Controls the depth of data generation:
  - `1`: Generates trades and quotes tables.
  - `2`: Generates trades, quotes, and depth tables.

**Examples**

```q
// Function signature:
mockData[syms; date; startTime; endTime; rowCnts; startPxs; level]
## Example
Below is an example of loading the module into a session and viewing the size of different objects.

// Loading the module into a session
md: use `di.mockDataGen

// Level 1: Generate trades and quotes for multiple instruments
// on a single trading day:
md.mockData[`AAPL`MSFT`META; 2025.01.10; 09:30:00; 16:00:00;
         `AAPL`MSFT`META!300 500 200;
         `AAPL`MSFT`META!22.33 38.34 29.43;
         1]

// Level 2: Generate trades, quotes, and depth for multiple instruments
// on a single trading day:
md.mockData[`AAPL`MSFT`META; 2025.01.10; 09:30:00; 16:00:00;
         `AAPL`MSFT`META!300 500 200;
         `AAPL`MSFT`META!22.33 38.34 29.43;
         2]
```

### ⚙️`mockDataR`

Generates mock data for the given multiple instruments in the given date range along with the following given parameters.

**Parameters**
- `syms`: Instruments/symbols for which the data is generated.
- `datelist`: List of dates for which the data is generated.
- `startTime`: Market open time or the starting time from which data generation begins.
- `endTime`: Market close time or the ending time up to which data is generated.
- `rowCnts`: Number of rows to generate the data for each syms. This should be passed as a dictionary, for example: `AAPL`MSFT`META!300 500 200 
- `startPxs`: Starting price of the given instruments of type float. Should be passed as a dictionary, for example: `AAPL`MSFT`META!22.33 38.34 29.43
- `level`: Controls the depth of data generation:
  - `1`: Generates trades and quotes tables.
  - `2`: Generates trades, quotes, and depth tables.

// Note
- For multi-day data generation, price continuity is maintained by using the previous day’s last traded price as the opening price for the following day.

**Examples**

```q
// Function signature:
mockDataR[syms; datelist; startTime; endTime; rowCnts; startPxs; level]

// Loading the module into a session
md: use `di.mockDataGen

// Level 1: Generate trades and quotes for multiple instruments
// on a single trading day:
md.mockDataR[`AAPL`MSFT`META; 2025.01.10 2025.01.11 2025.01.12; 09:30:00; 16:00:00;
         `AAPL`MSFT`META!300 500 200;
         `AAPL`MSFT`META!22.33 38.34 29.43;
         1]

// Level 2: Generate trades, quotes, and depth for multiple instruments
// on a single trading day:
md.mockDataR[`AAPL`MSFT`META; 2025.01.10 2025.01.11 2025.01.12; 09:30:00; 16:00:00;
         `AAPL`MSFT`META!300 500 200;
         `AAPL`MSFT`META!22.33 38.34 29.43;
         2]
```
     

### ⚙️`mockHdb`

writes down the data to the specified HDB directory 

**Parameters**
- `dir`: Target HDB directory where the generated data will be written.
- `syms`: List of instrument symbols for which data is generated and saved to HDB.
- `dates`: List of trading dates for which data will be generated and persisted.
- `startTime`: Market open time or the starting timestamp from which data generation begins.
- `endTime`: Market close time or the ending timestamp up to which data is generated.
- `rowCnts`: Number of rows to generate per instrument.  
  This must be provided as a dictionary, for example:  
  `AAPL`MSFT`META!300 500 200
- `startPxs`: Starting price for each instrument, specified as floating-point values.  
  This must be provided as a dictionary, for example:  
  `AAPL`MSFT`META!22.33 38.34 29.43
- `level`: Controls the depth of data generation:
  - `1`: Generates and saves trades and quotes tables.
  - `2`: Generates and saves trades, quotes, and depth tables.

// Note
- price continuity is maintained by using the previous day’s last traded price as the opening price for the following day.

**Examples**

```q
// Function signature:
mockHdb[dir; syms; dates; startTime; endTime; rowCnts; startPxs; level]

// Loading the module into a session
md: use `di.mockDataGen

// Level 1: Generate trades and quotes for multiple instruments
// on a single trading day:
md.mockHdb[`:hdb;`AAPL`MSFT`META; 2025.01.10 2025.01.11 2025.01.12; 09:30:00; 16:00:00;
         `AAPL`MSFT`META!300 500 200;
         `AAPL`MSFT`META!22.33 38.34 29.43;
         1]

// Level 2: Saves dwon the generated trades, quotes, and depth for multiple instruments to a specified HBD directory
// on a single trading day:
md.mockHdb[`:hdb;`AAPL`MSFT`META; 2025.01.10 2025.01.11 2025.01.12; 09:30:00; 16:00:00;
         `AAPL`MSFT`META!300 500 200;
         `AAPL`MSFT`META!22.33 38.34 29.43;
         2]

// to view the data in HDB
\l hdb
select from trades

time                          sym  src price size 
--------------------------------------------------
2025.01.10D09:32:15.619000000 AAPL O   22.34 1283 
2025.01.10D09:32:46.924000000 AAPL O   22.38 8105 
2025.01.10D09:32:48.758000000 AAPL O   22.34 263  
2025.01.10D09:33:30.234000000 AAPL N   22.31 474  
2025.01.10D09:34:04.825000000 AAPL N   22.36 131  
2025.01.10D09:34:15.211000000 AAPL O   22.33 8281 

```