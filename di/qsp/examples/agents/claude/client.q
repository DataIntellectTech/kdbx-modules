/ a client for an agent:   q di/qsp/examples/agents/claude/client.q -call CALL [-user USER] [-direct] [-query Q] [-port 5100]
/ makes one `.qsp.api or `.qsp.execasx call, prints the result, and exits 0 (or 1 on refusal/error).
/ With -direct it logs in as USER, so qsp takes the user from the connection and no message can
/ name anyone else: how an agent bound to one user connects. Without it, it logs in as gateway and
/ names USER in each message, which can be anyone - the demo mode, for trying several roles.
/ calls:
/   users      who may connect (`.qsp.api;`users;`json)
/   describe   everything USER needs to know before writing q (`.qsp.api;`describe;USER;`json)
/   rules      the rules for writing q that qsp accepts (`.qsp.api;`rules;`json)
/   primer     how to write q that qsp accepts, as markdown for the agent's context (`.qsp.api;`primer)
/   validate   check QUERY as USER without running it (`.qsp.api;`validate;USER;QUERY;`json)
/   explain    show QUERY as qsp would run it for USER (`.qsp.api;`explain;USER;QUERY)
/   estimate   how big QUERY is before it runs: rows and bytes it reads and returns, against the limits
/   query      run QUERY as USER via (`.qsp.execasx;QUERY;USER) and show the result and what ran

\c 50 200
o:.Q.opt .z.x;
port:$[`port in key o;first o`port;"5100"];
host:$[`host in key o;first o`host;"localhost"];
call:$[`call in key o;`$first o`call;`describe];
user:$[`user in key o;`$first o`user;`llm1];
qry:$[`query in key o;" "sv o`query;""];
direct:`direct in key o;
/ -json: query's result as data - see asjson; -rows N: how many rows of it to send (default 100)
asjsonout:`json in key o;
nrows:$[`rows in key o;"J"$first o`rows;100];

login:$[direct;string user;"gateway"];
addr:`$":",host,":",port,":",login,":x";
h:@[hopen;addr;{-2"cannot connect to ",string[addr]," - start server.q first (",x,")";exit 1}];

/ a result as data an agent can read whole: what ran, the full row count, the columns and their
/ types, the first n rows, and whether those are all of them. A printout is cut to the console
/ (\c), loses types, and hides how many rows there were
asjson:{[ran;res;n]
  t:$[99h=type res;$[98h=type key res;0!res;enlist res];98h=type res;res;()];
  if[count t;
    m:0!meta t;
    :`ran`rows`columns`types`data`truncated!(ran;count t;m`c;string m`t;n sublist t;n<count t)];
  :`ran`rows`columns`types`data`truncated!(ran;count res;();enlist .Q.t abs type res;res;0b);
  };

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

if[call=`brief;
  msg:$[direct;(`.qsp.api;`brief;`json);(`.qsp.api;`brief;user;`json)];
  r:send msg;
  if[not r 0;-2"refused: ",r 1;exit 1];
  -1 r 1;
  exit 0];

if[call=`rules;
  r:send (`.qsp.api;`rules;`json);
  if[not r 0;-2"refused: ",r 1;exit 1];
  -1 r 1;
  exit 0];

if[call=`primer;
  r:send (`.qsp.api;`primer);
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

if[call=`estimate;
  if[0=count qry;-2"estimate needs -query \"select ...\"";hclose h;exit 2];
  msg:$[direct;(`.qsp.api;`estimate;qry;`json);(`.qsp.api;`estimate;user;qry;`json)];
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
  / the same message either way: a gateway names the user, and a user's own login may name itself
  msg:(`.qsp.execasx;qry;user);
  r:send msg;
  if[not r 0;-2"refused: ",r 1;exit 1];
  res:r[1;0];
  ran:r[1;1];
  if[asjsonout;-1 .j.j asjson[ran;res;nrows];exit 0];
  if[count ran;-1"== ran as ",string[user],":\n  ",ran,"\n"];
  -1"== result (",$[98h=type res;string[count res]," rows";99h=type res;$[98h=type key res;string[count res]," rows";"dict"];"value"],"):";
  -1 .Q.s 100 sublist res;
  exit 0];

hclose h;
-2"unknown -call ",string[call]," (expected users, describe, rules, primer, validate, explain, estimate or query)";
exit 2;
