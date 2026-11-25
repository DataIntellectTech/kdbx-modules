/ does this function do anything besides return its result?
/ around applies a function and reports what it changed. Useful when reviewing a function, and in
/ tests, to assert a function has no side effects
/   q examples/02_functionsideeffects.q -q

st:use`di.state;

trade:([]sym:`a`b`a`c;price:10 20 11 30f;size:100 200 300 400);
.z.ts:{[x] };
system"t 1000";

eod:{[dt]
  / end-of-day summary - meant only to return a table
  s:select vwap:size wavg price,vol:sum size by sym from trade;
  `lastsummary set s;
  delete from`trade;
  system"t 0";
  :s;
  };

r:st.around[eod;enlist .z.d];

-1"== what eod returned";
show r`result;

-1"\n== what eod changed";
show select ns,name,kind,change from r`changes;

-1"\n== trade, before and after";
show exec first before,first after from r[`changes]where name=`trade;

/ a side-effect check, for a test: 1b if f changes nothing
pure:{[f;args] :0=count st.around[f;args]`changes;};

-1"\n== pure checks";
-1"vwap is pure: ",string pure[{[t] :select vwap:size wavg price by sym from t;};enlist trade];
-1"eod is pure:  ",string pure[eod;enlist .z.d];

exit 0;
