/ di.html integration test
/ starts a plain-text-mode websocket process for browser testing without c.js
/ usage: q di/html/integrationtest.q (from kdbx-modules root, after setting QPATH)
/ pass -p PORT to use a specific port; otherwise the OS assigns a free port

if[0=system"p"; system"p 0"];

html:use`di.html;

logdep:`info`warn`error!(
  {[c;m] -1 "[INFO] ",string[c]," ",m};
  {[c;m] -1 "[WARN] ",string[c]," ",m};
  {[c;m] -2 "[ERROR] ",string[c]," ",m});

/ set KDBHTML to this file's directory so test.html can be served over http
/ .z.f is the script path; split on "/" and drop the filename component
setenv[`KDBHTML;"/" sv -1_"/" vs string .z.f];
html.init[enlist[`log]!enlist logdep];

/ sample tables
trades:([]time:`timestamp$();sym:`symbol$();px:`float$();sz:`long$());
quotes:([]time:`timestamp$();sym:`symbol$();bid:`float$();ask:`float$());
html.addtables[`trades`quotes];

/ plain browsers have no c.js, so send updates as json text rather than the default c.js binary
html.setmodifier[;{.j.j `name`data!("upd";`tablename`tabledata!(x 1;x 2))}] each `trades`quotes;

/ override .z.ws with a plain-text json handler
/ sub takes json strings itself; tick needs its table name as a symbol and its row count as a long
.z.ws:{
  d:.j.k x;
  if[(`func in key d) and d[`func]~"tick";
    d:@[d;`arg1`arg2;:;(`$d`arg1;"j"$d`arg2)]];
  neg[.z.w] .j.j html.evaluate d;
  };

/ generate n rows of fake data and publish through the module, so each subscriber's sym filter applies
tick:{[t;n]
  tm:n#.z.p;
  syms:n?`AAPL`MSFT`GOOG`AMZN;
  data:$[t=`trades;
    ([]time:tm;sym:syms;px:100f+n?1f;sz:n?100);
    ([]time:tm;sym:syms;bid:99f+n?1f;ask:101f+n?1f)
    ];
  html.pub[t;data];
  };

p:string system"p";
-1 "di.html integration test ready on port ",p;
-1 "open test.html in browser, or browse to http://localhost:",p,"/test.html";
-1 "q commands: tick[`trades;5] , tick[`quotes;5]";
