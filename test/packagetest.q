// Generic test script to be ran for individual packages

\l test/k4unit.q

.test.main:{
    if[""~p:first (.Q.opt .z.x)`package;'`noPackageDefined];
    $[not ()~key tp:hsym `$p,"/test.csv";KUltf tp;'`noTestCsv];
    system "l ",p,"/",p,".q";
    KUrt[];
    show `ok xasc KUTR;
    };
.test.main[];
