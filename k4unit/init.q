/ generic test script to be ran for individual packages

\l k4unit/k4unit.q
\l k4unit/mock.q

packagetest:{[p]
  // check if package is loaded 
  //if[not (`$p) in key`.z.m;
    //'"package is not loaded"];


  / Check if package passed either by function variable or in command line 
  $[not ()~key tp:hsym `$p,"/test.csv";KUltf tp;'"no test csv"];
  
  
  // Maintained logic of test helper script (not sure if we need to remove or not)
  if[`test.q in key hsym`$p;system"l ",p,"/test.q"]; / Load any required helper code
  KUrt[];
  -1"Test results:";
  show KUTR;
  $[count failures:select from KUTR where not ok;
    [-1"Test failures:";show failures];
    -1"All tests passed"];
  };
  

export:([packagetest:packagetest])
