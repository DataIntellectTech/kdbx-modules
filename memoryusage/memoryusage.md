# Memory Usage
This package can be used to calculate the approximate size of an object in memory, or for generating a table containing the approximate size of each object in memory.

## Main funtions
The package contains two methods for calculating memory usage. 

The `memusage` functions generate a table containing the approximate memoryusage of each object in the kdb session in bytes / megabytes using -22!. This can be useful quick approximations. 

`memusagevars[]`:Generates a table of the approximate memory usage statistics of all variables in a kdb session.

`memusageall[]`:Generates a table of the approximate memory usage statistics of all variables and views in a kdb session.

----

The `objsize` function is more computationally expensive, it tries to calculate the actual memory size of an object by including nested types and attributes.

`objsize[]`:Returns the approximate size of an individual kdb object including nested types and attributes.

## memusage table schema
The memusage table is returned from either the `memusagevars` or `memusageall` functions.

| Column   | Type        | Description                                 |
|----------|-------------|---------------------------------------------|
| variable | `symbol`    | Namespace and name of variable              |
| size     | `long`      | The approximate size of the object in bytes |
| sizeMB   | `int`       | The approximatee size of the object in MB   | 

## Example
Below is an example of loading the package into a session and viewing the size of different objects.

```q
\\ Loading the package into a session
memusage: use `memoryusage

\\ View dictionary of functions
memusage

objsize     | `.m.memoryusage.export.objsize[]
memusageall | `.m.memoryusage.export.memusageall[]
memusagevars| `.m.memoryusage.export.memusagevars[]

\\ Calculating the memory usage of an object

a:1 / - an atom should return 16

b: ([]a:`a`b`c; b:1 2 3)

memusage.objsize[a]

memusage.objsize[b]

// View a and b in the memusage table

select from memusage.memusagevars[] where  variable in `..a`..b

variable size sizeMB
--------------------
..b      69   0
..a      17   0

```