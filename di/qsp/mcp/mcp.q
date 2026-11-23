/ qsp's MCP server: an agent's tools for a qsp-policed kdb+ process, over MCP's stdio transport
/   di/qsp/mcp/qsp-mcp -port 5100 -user llm1                      bound: every call runs as llm1
/   di/qsp/mcp/qsp-mcp -port 5100 -gateway gateway [-default llm1]  demo: each tool names its user
/   options: -host H (localhost) -pass P (x) -rows N (100, rows of a result sent back)
/ An MCP client - Claude Code, or any other - starts this as a command and talks JSON-RPC on its
/ stdin and stdout, one message per line. It connects to a policed process over IPC and exposes
/ qsp's own calls as tools: brief, describe, rules, primer, validate, explain, estimate, query,
/ history and term. Bound, it logs in as the user, so qsp takes the user from the connection and
/ no call can name anyone else - how an agent acting for one person should connect. In demo mode
/ it logs in as a gateway and each tool takes the user to act as, for trying several roles.
/ It must run with -q, or q's banner would be the first thing on stdout: qsp-mcp, beside this
/ file, always passes it. Nothing but protocol messages is written to stdout; diagnostics go to
/ stderr. It implements the part of MCP a tool server needs - initialize, ping, tools/list and
/ tools/call - for protocol versions 2024-11-05 to 2025-06-18.

.Q.m.SP:(enlist {[f] $[count i:where f="/";(1+last i)#f;"./"],"../../../"} string .z.f),.Q.m.SP;
api:use`di.qsp.api;

o:.Q.opt .z.x;
opt:{[k;d] :$[k in key o;" " sv o k;d];};
host:opt[`host;"localhost"];
port:opt[`port;"5100"];
pass:opt[`pass;"x"];
bound:`user in key o;
login:`$$[bound;opt[`user;""];opt[`gateway;"gateway"]];
defaultuser:`$opt[`default;"llm1"];
nrows:"J"$opt[`rows;"100"];
if[null nrows;nrows:100];

versions:("2025-06-18";"2025-03-26";"2024-11-05");
servername:"qsp";
version:@[{first read0 x};hsym `$.Q.m.mp[`di.qsp],"/VERSION";{"0"}];

/ ------------------------------------------------------------------ the connection
/ opened on first use and again after it drops, so a server restarted under a running agent is
/ picked up on the next call rather than ending the session

h:0Ni;
connect:{[]
  if[not null h;:h];
  a:`$":",host,":",port,":",string[login],":",pass;
  r:@[{(1b;hopen (x;5000))};a;{(0b;x)}];
  if[not r 0;'"cannot connect to qsp at ",host,":",port," as ",string[login]," - is the server running? (",r[1],")"];
  h::r 1;
  :h;
  };
/ the client closing stdin is how MCP ends a stdio session: q reports it as handle 0 closing.
/ With a connection open q would otherwise keep running, so exit then
.z.pc:{[w] if[w=0;exit 0]; if[w=h;h::0Ni];};

/ send msg, reconnecting once if the handle had dropped
ask:{[msg]
  r:@[{(1b;connect[] x)};msg;{(0b;x)}];
  if[r 0;:r 1];
  if[r[1] like "qsp: *";'r 1];
  h::0Ni;
  :connect[] msg;
  };

/ ------------------------------------------------------------------ the tools

/ the user a call acts as: the login when bound, else the tool's user argument or the default
userof:{[a]
  u:$[`user in key a;`$a`user;`];
  if[bound;
    if[not null u;if[not u=login;'"this server is bound to qsp user ",string[login],": every call runs as ",string[login],", and it cannot act as ",string u]];
    :login];
  :$[null u;defaultuser;u];
  };

/ an api message, naming the user only in demo mode: bound, qsp takes it from the login
apimsg:{[call;a;args;fmt] :(`.qsp.api;call),$[bound;();enlist userof a],args,$[null fmt;();enlist fmt];};

/ a result as data an agent can read whole: what ran, the full row count, the columns and their
/ types, the first nrows rows, and whether those are all of them
asdata:{[ran;res]
  t:$[99h=type res;$[98h=type key res;0!res;()];98h=type res;res;()];
  if[count t;
    m:0!meta t;
    :`ran`rows`columns`types`data`truncated!(ran;count t;m`c;string m`t;nrows sublist t;nrows<count t)];
  if[(98h=type res)or 99h=type res;:`ran`rows`columns`types`data`truncated!(ran;0;cols res;"";res;0b)];
  :`ran`rows`columns`types`data`truncated!(ran;count res;();enlist .Q.t abs type res;res;0b);
  };

querytool:{[a]
  q:a`query;
  tree:10h=type q;
  if[not tree;'"query must be a string of q-SQL"];
  r:ask (`.qsp.execasx;q;userof a);
  :api.encode[`json;asdata[r 1;r 0]];
  };

/ a term's arguments arrive as JSON: strings, numbers, lists. Read each as the type the term
/ declares, as qsp's terms.csv examples are read, so qsp receives typed values and never text
termargs:{[u;n;args]
  b:ask $[bound;(`.qsp.api;`brief);(`.qsp.api;`brief;u)];
  t:b`terms;
  i:(`symbol$t`term)?n;
  if[i=count t;'"no term ",string[n]," that ",string[u]," can read"];
  ps:{[s] $[0=count s;(`symbol$())!"";{(`$x[;0])!raze x[;1]} {":" vs trim x} each "," vs s]} t[i;`params];
  if[0=count ps;:()];
  if[not 99h=type args;'"args must be an object of the term's parameters: ",t[i;`params]];
  k:key ps;
  miss:k except key args;
  if[count miss;'"term ",string[n]," needs ",", " sv string miss];
  :k!{[t;v] s:$[10h=type v;enlist v;0h=type v;v;string v];
      s:{$[10h=type x;x;string x]} each s;
      $[t="s";`$first s;t="S";`$s;t in .Q.A;t$s;(upper t)$first s]}'[ps k;args k];
  };

termtool:{[a]
  u:userof a;
  n:`$a`term;
  args:termargs[u;n;$[`args in key a;a`args;()!()]];
  q:ask $[bound;(`.qsp.api;`term;n;args);(`.qsp.api;`term;u;n;args)];
  r:ask (`.qsp.execasx;q;u);
  :api.encode[`json;asdata[r 1;r 0]];
  };

who:$[bound;"`",string[login],"`, the user this server is bound to";"`user`"];
userarg:$[bound;()!();enlist[`user]!enlist `type`description!("string";"Policy user to act as (default ",string[defaultuser],")")];
queryarg:enlist[`query]!enlist `type`description!("string";"The q-SQL query, as one string");

/ name -> (description; extra properties; required; handler)
tools:(`symbol$())!();
addtool:{[n;d;props;req;f] @[`tools;n;:;(d;props;req;f)];};

addtool[`qsp_brief;"What ",who," may read, in brief: tables, granted columns and types, partition column, row filter, the data's shape (visible dates, few-valued codes), limits, business terms and whether they may export. Call it before writing q.";
  ()!();();{[a] ask apimsg[`brief;a;();`json]}];
addtool[`qsp_describe;"Everything qsp knows about what ",who," may read: brief, plus the function whitelist and the rules.";
  ()!();();{[a] ask apimsg[`describe;a;();`json]}];
addtool[`qsp_rules;"The rules for writing q that qsp accepts, each with its reason, queries that pass and fail, and the refusal text it produces. Match a refusal to its rule here.";
  ()!();();{[a] ask (`.qsp.api;`rules;`json)}];
addtool[`qsp_primer;"How to write q that qsp accepts, as markdown: a method for any question, the q that matters, the shapes qsp takes, techniques, and what each refusal means. Read it before your first query unless it is already in your context.";
  ()!();();{[a] ask (`.qsp.api;`primer)}];
addtool[`qsp_validate;"Whether a query would be allowed for ",who,", without running it. Refused, it gives the reason, the rule, and the refusal as data: code, kind (permission, shape, limit, runtime) and subject.";
  queryarg;enlist"query";{[a] ask apimsg[`validate;a;enlist a`query;`json]}];
addtool[`qsp_explain;"The query exactly as qsp would run it for ",who,", with the row filter and columns in place.";
  queryarg;enlist"query";{[a] ask apimsg[`explain;a;enlist a`query;`json]}];
addtool[`qsp_estimate;"How big a query is for ",who," before it runs: rows and bytes it reads per table, its result's size, the limits, and a verdict (fits, large, toobig) with what to change.";
  queryarg;enlist"query";{[a] ask apimsg[`estimate;a;enlist a`query;`json]}];
addtool[`qsp_query;"Run a q-SQL query as ",who,". Returns JSON: ran (what qsp actually ran), rows (the full count), columns, types, data (the first ",string[nrows]," rows) and truncated. A refusal comes back as an error starting qsp:.";
  queryarg;enlist"query";querytool];
addtool[`qsp_history;"The last n decisions qsp made on ",who,"'s queries: what was sent, what ran, allowed or not, and why.";
  enlist[`n]!enlist `type`description!("integer";"How many (default 15)");();
  {[a] ask apimsg[`history;a;enlist $[`n in key a;`long$a`n;15];`json]}];
addtool[`qsp_term;"Run one of the business's terms - a definition from brief's terms - with its parameters, as ",who,". Returns what qsp_query returns.";
  (`term`args)!(`type`description!("string";"The term's name");`type`description!("object";"Its parameters by name, e.g. {\"date\":\"2026.10.08\",\"sym\":\"NVDA\"}"));
  enlist"term";termtool];
if[not bound;addtool[`qsp_users;"The users and gateway logins of the policy on the server: who you can act as.";()!();();{[a] ask (`.qsp.api;`users;`json)}]];

tooldefs:{[]
  :{[n;t] p:userarg,t 1;
    s:`type`properties!("object";$[count p;p;()!()]);
    if[count t 2;s[`required]:t 2];
    :`name`description`inputSchema!(string n;t 0;s)}'[key tools;value tools];
  };

instructions:$[bound;"This server is bound to qsp user ",string[login],": every call runs as them, and no tool can act as anyone else. ";
  "Demo mode: each tool takes the qsp user to act as. "],
  "qsp polices every query: it parses it, checks every part, rewrites it to apply the user's row filter and columns, and only then runs it. ",
  "Before your first query, read the primer (qsp_primer) unless it is already in your context, and call qsp_brief. ",
  "Check a query with qsp_validate or qsp_estimate before running anything large. ",
  "A refusal names the rule that explains it: read that rule (qsp_rules) and change the query, rather than retrying it unchanged.";

/ ------------------------------------------------------------------ JSON-RPC

out:{[m] -1 .j.j m;};
reply:{[id;r] out `jsonrpc`id`result!("2.0";id;r);};
fail:{[id;c;m] out `jsonrpc`id`error!("2.0";id;`code`message!(c;m));};

/ a tool's text reply: success, or an error the model reads and can act on
text:{[t;iserr] :`content`isError!(enlist `type`text!("text";t);iserr);};

calltool:{[p]
  n:`$p`name;
  if[not n in key tools;:text["unknown tool: ",string n;1b]];
  a:$[`arguments in key p;p`arguments;()!()];
  if[not 99h=type a;a:()!()];
  r:@[{(1b;x y)}[last tools n];a;{(0b;x)}];
  :$[r 0;text[$[10h=type r 1;r 1;api.encode[`json;r 1]];0b];text[r 1;1b]];
  };

handle:{[m]
  if[not 99h=type m;:fail[0N;-32600;"invalid request"]];
  isreq:`id in key m;
  id:$[isreq;m`id;(::)];
  me:$[`method in key m;m`method;""];
  p:$[`params in key m;m`params;()!()];
  if[not isreq;:()];
  if[me~"initialize";
    v:$[`protocolVersion in key p;p`protocolVersion;first versions];
    :reply[id;`protocolVersion`capabilities`serverInfo`instructions!(
      $[v in versions;v;first versions];enlist[`tools]!enlist enlist[`listChanged]!enlist 0b;
      `name`version!(servername;version);instructions)]];
  if[me~"ping";:reply[id;()!()]];
  if[me~"tools/list";:reply[id;enlist[`tools]!enlist tooldefs[]]];
  if[me~"tools/call";:reply[id;calltool p]];
  fail[id;-32601;"method not found: ",me];
  };

/ one line from the client: a message, or (2025-03-26) a batch of them
line:{[x]
  x:trim x;
  if[0=count x;:()];
  m:@[.j.k;x;{(::)}];
  if[(::)~m;:fail[(::);-32700;"parse error"]];
  $[98h=type m;handle each m;(0h=type m)&0<count m;handle each m;handle m];
  };

.z.pi:{[x] @[line;x;{[e] -2"qsp mcp: ",e;}];};
