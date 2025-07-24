/ generic test script to be ran for individual packages

\l test/k4unit.q

.test.main:{
  if[""~p:first (.Q.opt .z.x)`package;'`noPackageDefined];
  $[not ()~key tp:hsym `$p,"/test.csv";KUltf tp;'`noTestCsv];
  system "l ",p,"/",p,".q";
  KUrt[];
  -1"Test results:";
  show KUTR;
  $[count failures:select from KUTR where not ok;
    -1"All tests passed";
    [-1"Test failures:";show failures]];
  };
.test.main[];
