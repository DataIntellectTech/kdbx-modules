
/ analytics/examples/ffill_example.q
/ run from repo root:
\l analytics/analytics.q




n:30;
prob:0.2;

genull:{
  / generate table with random missing values (null)
    t:([]time:n?.z.P;sym:n?`AMD`AAPL`MSFT`IBM;ask:n?100f;bid:n?100f;asize:n?500i;bsize:n?500i;ex:n?`NYSE`CME`LSE);
    t:`time`sym xasc t;
    t:update ask:?[prob>n?1f;0n;ask] from t;
    t:update bid:?[prob>n?1f;0n;bid] from t;
    t:update asize:?[prob>n?1f;0n;asize] from t;
    t:update bsize:?[prob>n?1f;0n;bsize] from t;
    t:update ex:?[prob>n?1f;`;ex] from t;
    :t
    };


genzero:{
  / generate table with random 0 values
  t:([]time:n?.z.P;sym:n?`AMD`AAPL`MSFT`IBM;ask:n?100f;bid:n?100f;asize:n?500i;bsize:n?500i;ex:n?`NYSE`CME`LSE);
  t:`time`sym xasc t;
  t:update ask:?[prob>n?1f;0;ask] from t;
  t:update bid:?[prob>n?1f;0;bid] from t;
  t:update asize:?[prob>n?1f;0;asize] from t;
  :t
  };



table:genull[];

/ case 1:
-1 "fill on table";
filledtable:.anl.ffill table;


/ case 2:
-1 "fill on dictionary with arg: by=sym; key=(ask,asize,bsize):";
args:(`table`by`keycols)!(table;`sym;`ask`asize`bsize);
filledtable:.anl.ffill args;


/ case 3:
-1 "fill on dictionary with arg: by=sym; key=ex:";
args:(`table`by`keycols)!(table;`sym;`ex);
filledtable:.anl.ffill args;



/ case 4:
-1 "fill on dictionary with arg: by=sym:";
args:(`table`by)!(table;`sym);
filledtable:.anl.ffill args;


/ case 5:
-1 "fill on dictionary with arg: keycols=ask:";
args:(`table`keycols)!(table;`ask);
filledtable:.anl.ffill args;


/ case 6:
-1 "fill on dictionary with arg: keycols=(ask,bid,asize):";
args:(`table`keycols)!(table;`ask`bid`asize);
filledtable:.anl.ffill args;


table:genzero[];


/ case 7:
-1 "fill on dictionary with arg: by=sym, keycols=(ask,bid):";
args:(`table`by`keycols)!(table;`sym;`ask`bid);
filledtable:.anl.ffillzero args;











