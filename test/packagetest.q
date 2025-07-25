// Generic test script to be ran for individual packages

\l test/k4unit.q
\l test/mock.q

.test.main:{
  if[""~p:first (.Q.opt .z.x)`package;'`noPackageDefined];
  $[not ()~key tp:hsym `$p,"/test.csv";KUltf tp;'`noTestCsv];
  system "l ",p,"/",p,".q";
  if["test.q"in system"ls ",p;system"l ",p,"/test.q"]; / Load any required helper code
  KUrt[];
  -1"Test results:";
  show KUTR;
  $[count failures:select from KUTR where not ok;
    [-1"Test failures:";show failures];
    -1"All tests passed"];
  };
.test.main[];
