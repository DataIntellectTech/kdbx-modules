# `dataloader.q` –  Loading delimited data and creating databases for kdb+


This module is used for automated customisable dataloading and database creation and is a generalisation of http://code.kx.com/wiki/Cookbook/LoadingFromLargeFiles. 
module employs a chunk-based loading strategy to minimize memory usage when processing large datasets. Rather than loading entire datasets into memory before writing to disk, data is processed incrementally in manageable chunks.

The memory footprint is determined by the maximum of:
- Memory required to load and save one data chunk
- Memory required to sort the final resultant table

This approach enables processing of large data volumes with a relatively small memory footprint. Example use cases include: 
- Large File Processing: Loading very large files by processing them in small, sequential chunks
- Cross-Partition Loading: Efficiently handling distributed data across multiple small files (e.g., separate monthly files for AAPL and MSFT data)

The chunked architecture ensures scalable performance regardless of total dataset size, making it suitable for processing datasets that would otherwise exceed available system memory.
When all the data is written, the on-disk data is re-sorted and the attributes are applied.

---

## :sparkles: Features

- Load delimited data from disk directory in customisable chunks
- Persist data to disk in partitioned format
- Dynamically sort and apply attributes to tables in the resulting database
- Configure compression of database

---

## :gear: Initialisation

After loading the module into the session, the `loadallfiles` function is ready to run. By default, tables will be written with the `p` attribute applied to the `sym` column and sorted. 

### :mag_right: Custom sorting parameters

By default, the sorting paramters for all tables are:
```
tabname att column sort
-----------------------
default p   sym    1
```

That is, for every table the `p` attribute will be applied to the `sym` column and sorted. If the table being loaded requires different attributes applied on different columns, custom sorting parameters can be added using the `addsortparams` function. This takes 4 inputs: tabname, att, column, and sort. These arguments are used to determine how the tables in the resulting database should be sorted and where attributes applied when being persisted. Furthermore, this will add (or update existing) parameters for the specified table.

You may apply default sorting and attributes to all tables loaded in by the module by passing in the `tabname` with a value of `default` and specifying your default sorting and attribute parameters. By passing in `default` this will overwrite the current default paramters.

If no sorting or attributes are required pass in the dictionary with a `tabname` with `default`, `att` and `column` with backticks and `sort` with `0b`, examples shown below:
```q
dataloader:use`di.dataloader
dataloader.addsortparams[`tabname`att`column`sort!(`default;`;`;0b)]                               / Overwrite default to apply no sorting or attributes
dataloader.addsortparams[`tabname`att`column`sort!(`default;`p;`sym;1b)]                           / Overwrite default to sort all tables loaded in by the sym column and apply the parted attribute
dataloader.addsortparams[`tabname`att`column`sort!(`default`trade`quote;`p`s`;`sym`time`;110b)]    / Apply default to all tables, however, sort trade by sym and apply `p and if quote is read in by the function then do not sort or apply attributes
```
The dictionary arguments are outlined below.

| Input     | Type                  | Description                                                                      |
|-----------|-----------------------|----------------------------------------------------------------------------------|
| `tabname` | symbol/ symbol list   | Name of table                                                                    |
| `att`     | symbol/ symbol list   | Attributes corresponding to the table names                                      |
| `column`  | symbol/ symbol list   | Columns to sort and apply attributes to                                          |
| `sort`    | boolean /boolean list | Determines if the corresponding table will be sorted (1b: sorted; 0b:not sorted) |

---

### :rocket: Functions

`loadallfiles` is the primary function used to load in all data and create the database. The function takes two arguments, a dictionary of loading parameters and a directory containing files to read. The function reads in all specified delimited files into memory from a chosen directory then proceeds to apply any required processing, persists the table to disk in a kdb+ partitioned format, compresses the files if directed and finally sorting and applying attributes.


## :mag_right: Params in depth
The dictionary should/can have the following fields:

| Parameter         | Required | Type      | Description                                                                                                                                                                     |
|-------------------|----------|-----------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `headers`         | Y        | symbol    | Names of the header columns in the file                                                                                                                                         |
| `types`           | Y        | char list | Data types to read from the file                                                                                                                                                |
| `separator`       | Y        | char list | Delimiting character. Enlist it if first line of file is header data                                                                                                            |
| `tablename`       | Y        | symbol    | Name of table to write data to                                                                                                                                                  |
| `dbdir`           | Y        | symbol    | Directory to write data to                                                                                                                                                      |
| `symdir`          | N        | symbol    | Directory to enumerate against                                                                                                                                                  |
| `enumname`        | N        | symbol    | Name of symfile to enumerate against. Default is `sym                                                                                                                           |
| `partitiontype`   | N        | symbol    | Partitioning to use. Must be one of `date, month, year, int`. Default is `date`                                                                                                 |
| `partitioncol`    | N        | symbol    | Column to use to extract partition information.Default is `time`                                                                                                                |
| `dataprocessfunc` | N        | function  | Diadic function to process data after it has been read in. First argument is load parameters dictionary, second argument is data which has been read in. Default is `{[x;y] y}` |
| `chunksize`       | N        | int       | Data size in bytes to read in one chunk. Default is `100 MB`                                                                                                                    |
| `compression`     | N        | int list  | Compression parameters to use e.g. `17 2 6`. Default is empty list for no compression                                                                                           |
| `gc`              | N        | boolean   | Whether to run garbage collection at appropriate points. Default is `0b` (false)                                                                                                |
| `filepattern`     | N        | char list | Pattern used to only load certain files e.g. `".csv"`,`("*.csv","*.txt")`                                                                                                       |

The second parameter is a directory handle .e.g 
```q
`:dir
```

---

### :test_tube: Example

```q
dataloader:use`di.dataloader

// If using custom sorting parameters, check they are as expected
dataloader.sortparams[]
tabname att column sort
-----------------------
default  p  sym    1

// Read in data and create db
dataloader.loadallfiles[`headers`types`separator`tablename`dbdir!(`sym`time`price`volume`mktflag`cond`exclude;"SPFICHB";",";`trade;`:hdb);`:TRADE/toload]

//load in db
\l hdb

//check table and sorting
select from trade

date       sym  time                          price volume mktflag cond exclude
-------------------------------------------------------------------------------
2025.07.15 AAPL 2025.07.15D01:17:08.000000000 266   3980   B       10   1
2025.07.15 AAPL 2025.07.15D01:44:42.000000000 278   31     B       12   1
2025.07.15 AAPL 2025.07.15D02:05:37.000000000 34    8699   S       21   0
2025.07.15 AAPL 2025.07.15D02:06:02.000000000 97    1769   B       29   1
2025.07.15 AAPL 2025.07.15D02:14:24.000000000 106   8138   B       2    1
2025.07.15 AAPL 2025.07.15D02:40:33.000000000 61    2611   B       36   1
2025.07.15 AAPL 2025.07.15D03:29:37.000000000 31    4240   B       15   1

// Ensure attributes are applied
meta trade
c      | t f a
-------| -----
date   | d
sym    | s   p
time   | p
price  | f
volume | i
mktflag| c
cond   | h
exclude| b
```
