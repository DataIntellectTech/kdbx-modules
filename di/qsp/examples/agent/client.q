/ a gateway client for an agent:   q di/qsp/examples/agent/client.q -call CALL [-user USER] [-query Q] [-port 5100]
/ connects to the policed server as gateway (or as USER when -direct is set), makes one `.qsp.api
/ or `.qsp.execas call, prints the result, and exits 0 (or 1 on refusal/error).
/ calls:
/   users      who may connect (`.qsp.api;`users;`json)
/   describe   everything USER needs to know before writing q (`.qsp.api;`describe;USER;`json)
/   rules      the rules for writing q that qsp accepts (`.qsp.api;`rules;`json)
/   validate   check QUERY as USER without running it (`.qsp.api;`validate;USER;QUERY;`json)
/   explain    show QUERY as qsp would run it for USER (`.qsp.api;`explain;USER;QUERY)
/   query      run QUERY as USER via (`.qsp.execasx;QUERY;USER) and show the result and what ran

\c 50 200
o:.Q.opt .z.x;
port:$[`port in key o;first o`port;"5100"];
host:$[`host in key o;first o`host;"localhost"];
call:$[`call in key o;`$first o`call;`describe];
user:$[`user in key o;`$first o`user;`llm1];
qry:$[`query in key o;" "sv o`query;""];
direct:`direct in key o;

login:$[direct;string user;"gateway"];
addr:`$":",host,":",port,":",login,":x";
h:@[hopen;addr;{-2"cannot connect to ",string[addr]," - start server.q first (",x,")";exit 1}];

send:{[msg]
  r:@[{(1b;h x)};msg;{(0b;x)}];
  hclose h;
  :r;
  };

if[call=`users;
  r:send (`.qsp.api;`users;`json);
  if[not r 0;-2"refused: ",r 1;exit 1];
  -1 r 1;
  exit 0];

if[call=`describe;
  msg:$[direct;(`.qsp.api;`describe;`json);(`.qsp.api;`describe;user;`json)];
  r:send msg;
  if[not r 0;-2"refused: ",r 1;exit 1];
  -1 r 1;
  exit 0];

if[call=`rules;
  r:send (`.qsp.api;`rules;`json);
  if[not r 0;-2"refused: ",r 1;exit 1];
  -1 r 1;
  exit 0];

if[call=`validate;
  if[0=count qry;-2"validate needs -query \"select ...\"";hclose h;exit 2];
  msg:$[direct;(`.qsp.api;`validate;qry;`json);(`.qsp.api;`validate;user;qry;`json)];
  r:send msg;
  if[not r 0;-2"refused: ",r 1;exit 1];
  -1 r 1;
  exit 0];

if[call=`explain;
  if[0=count qry;-2"explain needs -query \"select ...\"";hclose h;exit 2];
  msg:$[direct;(`.qsp.api;`explain;qry);(`.qsp.api;`explain;user;qry)];
  r:send msg;
  if[not r 0;-2"refused: ",r 1;exit 1];
  -1 r 1;
  exit 0];

if[call=`query;
  if[0=count qry;-2"query needs -query \"select ...\"";hclose h;exit 2];
  msg:$[direct;qry;(`.qsp.execasx;qry;user)];
  r:send msg;
  if[not r 0;-2"refused: ",r 1;exit 1];
  res:$[direct;r 1;r[1;0]];
  ran:$[direct;"";r[1;1]];
  if[count ran;-1"== ran as ",string[user],":\n  ",ran,"\n"];
  -1"== result (",$[98h=type res;string[count res]," rows";99h=type res;$[98h=type key res;string[count res]," rows";"dict"];"value"],"):";
  -1 .Q.s 100 sublist res;
  exit 0];

hclose h;
-2"unknown -call ",string[call]," (expected users, describe, rules, validate, explain or query)";
exit 2;
