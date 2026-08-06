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

/ resolve the html module namespace for direct state access
hns:` sv `.m.di,first (key `.m.di) where (key `.m.di) like "*html";

/ override .z.ws with a plain-text json handler
/ converts string arg1 to symbol and json numeric arg2 to long for functions that need it
.z.ws:{
  d:.j.k x;
  if[(`func in key d) and (d[`func] in ("sub";"tick"));
    if[`arg1 in key d; d:@[d;`arg1;`$]]];
  if[(`func in key d) and (d[`func]~"sub");
    if[`arg2 in key d; d:@[d;`arg2;`$]]];
  if[(`func in key d) and (d[`func]~"tick");
    if[`arg2 in key d; d:@[d;`arg2;"j"$]]];
  neg[.z.w] .j.j html.evaluate d;
  };

/ generate n rows of fake data and send as plain json text directly to subscribed browser handles
/ bypasses the module modifier (which sends c.js binary) so plain browsers can receive the data
tick:{[t;n]
  tm:n#.z.p;
  syms:n?`AAPL`MSFT`GOOG`AMZN;
  data:$[t=`trades;
    ([]time:tm;sym:syms;px:100f+n?1f;sz:n?100);
    ([]time:tm;sym:syms;bid:99f+n?1f;ask:101f+n?1f)
    ];
  msg:.j.j `name`data!("upd";`tablename`tabledata!(t;data));
  tsubs:(get ` sv hns,`subs) t;
  if[count tsubs; {[m;s] (neg s 0) m}[msg;] each tsubs];
  };

p:system"p";
-1 "di.html integration test ready on port ",p;
-1 "open test.html in browser, or browse to http://localhost:",p,"/test.html";
-1 "q commands: tick[`trades;5] , tick[`quotes;5]";
