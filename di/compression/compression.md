# Compression

`compression.q` applies compression to any kdb+ database, handles all partition types including date, month, year, int, and can deal with top level splayed tables. It will also decompress files as required.

> **Note:** Please use with caution

---

## :sparkles: Features

- Apply compression to any kdb+ database
- Compression uses -19! operator
- Configured using specified csv driver file
- Compression algorithm (none, kdb+ IPC, gzip), compression blocksize, and compression level (for gzip) can be configured
- Flexibility to compress different tables/columns with different compression parameters
- Preview available before compression to display files to be compressed and how
- Summary statistics for each file returned after compression/decompression complete

---

## memo: Dependencies

- KX log module

---

## :gear: compressioncsv Schema

Blank compressioncsv is created when module is loaded. 
loadcsv or showcomp functions accept `:/path/to/csv argument to specify driver csv location and will load the config to compressioncsv

| Column     | Type    | Description                                            |
|------------|---------|--------------------------------------------------------|
| table      | `symbol`| table names for specific compression                   |
| minage     | `int`   | minimum age of file in days before compression applied |
| column     | `symbol`| column name for column specific compression            |
| calgo      | `int`   | compression algorithim - 0, 1, or 2 accepted           |
| cblocksize | `int`   | compression blocksize - between 12 and 19              |
| clevel     | `int`   | compression level - 0 to 9 - for gzip (2) only         |

## :label: Example Config

```
table,minage,column,calgo,cblocksize,clevel
default,10,default, 2, 17,6
quotes, 10,time, 2, 17, 5
quotes,10,src,2,17,4
depth, 10,default, 1, 17, 8
```

- tables in the db but not in the config tab are automatically compressed using default params
- tabs with cols specified will have other columns compressed with default (if default specified for cols of tab, all cols are comp in that tab)
- algo 0 decompresses the file, or if not compressed ignores
- config file could just be one row to compress everything older than age with the same params:

---

## :wrench: Functions

| Function           | Description                                                    |
|--------------------|----------------------------------------------------------------| 
|`showcomp`          | Load specified compression config and show compression details for files to be compressed |
|`getcompressioncsv` | get function to return loaded compressioncsv config            |
|`compressmaxage`    | Compress files according to config up to the specified max age |
|`docompression`     | Compress all files in hdb according to compressioncsv config   |
|`getstatstab`       | get function to retrieve summary stats post compression        |

---

## :test_tube: Example

```q
// Include compression module in a process
cmp:use`di.compression

// View dictionary of functions
cmp

// Show table of files to be compressed and how before execution
cmp.showcomp[`:/path/to/hdb;`:/path/to/csv; maxagefilestocompress]

// COMPRESS all files up to a max age:
cmp.compressmaxage[`:/path/to/hdb;`:/path/to/csv; maxagefilestocompress]
 
// COMPRESS up to the oldest files in the db:
cmp.docompression[`:/path/to/hdb;`:/path/to/csv]

// Retrieve summary statistics for compression
cmp.getstatstab[]

```
