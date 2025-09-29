# Data Intellect KDB-X Module Consistency Guide

## Package Contents
Every package must have: 
1. The code 
2. Documentation in a .md file
3. Tests, conforming to k4unit

The tests should be runnable as 

```q
/ insert code here to run tests
```

## Paths 

Use module local paths for loading and file references

```q
/ local loading
\l ::local/path/to/file.q

/ local path
get`:::local/path/to/datafile
```

## Export

Only export the functions which should be called externally. 

## Namespaces

Avoid `\d` namespace switches.
