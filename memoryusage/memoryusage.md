# Memory Usage
This package can be used to calculate the aproximate size of an object in memory, or for generating a table containing the aproximate size of each object in memory.

## Main funtions
`objsize`   :   Fucntion returns the approximate memory size of a kdb+ object.

`memusage`  :   Function for viewing the approximate memory usage statistics of a kdb session.

## memusage table schema

| Column   | Type        | Description                                |
|----------|-------------|--------------------------------------------|
| variable | `symbol`    | Namespace and name of variable             |
| size     | `long`      | The aproximate size of the object in bytes |
| sizeMB   | `int`       | The aproximate size of the object in MB    | 

## Example
Below is an example of loading the package into a session and viewing the size of diffrent objects.

```q
\\ Loading the package into a session
memusage: use `memoryusage

\\ View dictionary of functions
memusage

objsize | `.m.memoryusage.export.objsize[]
memusage| `.m.memoryusage.export.memusage[]

\\ Calculating the memory usage of an object

a:1 / - an atom should return 16

b: ([]a:`a`b`c; b:1 2 3)

memusage.objsize[a]

memusage.objsize[b]
```