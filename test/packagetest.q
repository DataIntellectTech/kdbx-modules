/ generic test script to be ran for individual packages

\l test/k4unit.q

.test.main:{
  if[""~p:first (.Q.opt .z.x)`package;'"no package defined"];
  $[not ()~key tp:hsym `$p,"/test.csv";KUltf tp;'"no test csv"];
  system "l ",p,"/",p,".q";
  KUrt[];
  -1"Test results:";
  show KUTR;
  $[count failures:select from KUTR where not ok;
    [-1"Test failures:";show failures];
    -1"All tests passed"];
  };
.test.main[];
