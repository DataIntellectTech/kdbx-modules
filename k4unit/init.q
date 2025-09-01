/ generic test script to be ran for individual packages

\l k4unit/k4unit.q

packagetest:{[p]

  / Load the Test CSv for the assocaited package 
  / First line of the package will load the package using the following format 
  / package:use`package 
  $[not ()~key tp:hsym `$p,"/test.csv";KUltf tp;'"no test csv"];

  KUrt[];
  -1"Test results:";
  show KUTR;
  $[count failures:select from KUTR where not ok;
    [-1"Test failures:";show failures];
    -1"All tests passed"];
  };
  

export:([packagetest:packagetest])
