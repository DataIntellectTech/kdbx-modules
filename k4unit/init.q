/ generic test script to be ran for individual packages

\l k4unit/k4unit.q

packagetest:{[p]
  / Load the Test CSv for the assocaited package 
  / First line of the package will load the package using the following format 
  / package:use`package 
  $[not ()~key tp:.Q.dd[hsym`$.Q.m.mp p;`test.csv];KUltf tp;'"no test csv"];

  KUrt[];
  -1"Test results:";
  show KUTR;
  $[count failures:select from KUTR where not ok;
    [-1"Test failures:";show failures];
    -1"All tests passed"];
  };
  
/ setter functions for config values
verbose:{[x:`b]VERBOSE::x}
debug:{[x:{$[x in 0 1 2;x;'"must be one of 0 1 2"]}]DEBUG::x}
delim:{[x:`c]DELIM::x}

export:([packagetest:packagetest;verbose:verbose;debug:debug;delim:delim;saveresults:KUstr;loadresults:KUltr])
