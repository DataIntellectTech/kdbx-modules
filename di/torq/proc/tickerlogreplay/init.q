\l ::tickerlogreplay.q

version:first read0`:::VERSION

/ the default sort config
sortdefault:("SSSB";enlist",")0:read0`:::sort.csv

export:([init;version])
