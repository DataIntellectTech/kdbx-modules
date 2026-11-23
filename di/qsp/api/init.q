/ di.qsp.api - facts about a policed process, and the policy as it applies to one user, for a
/ gateway or a query generator to read before it writes q. Every function here takes the policy
/ as a value, like the rest of the module; over IPC the same calls are made by name against the
/ served policy, as (`.qsp.api;name;...) - see init.q
/ every endpoint takes a format as its last argument: `q gives the q value, `json the same
/ content as one JSON string. The format changes the encoding, never the content - every key is
/ in both, in the same place - so a gateway can switch between them without rewriting its reader

pol:use`..policy;
rev:use`..policy.review;
tree:use`..core.tree;

/ ------------------------------------------------------------------ formats

formats:`q`json;
chkformat:{[f] tree.chk[$[-11h=type f;f in formats;0b];"format must be `q or `json, not ",-3!f];};

/ a number type's infinities, which mean "no limit" wherever qsp uses them
infs:(5 6 7 8 9h)!(-0W 0Wh;-0W 0Wi;-0W 0W;-0w 0we;-0w 0w);

jsonable:{[x]
  / x, with what JSON cannot say said another way. q writes an infinite float as inf, which is
  / not JSON, and 0W as a 19-digit number that means nothing to a reader: both are null, which
  / the endpoints document as "no limit". A null symbol is null too, rather than ""
  t:type x;
  if[t=0h;:.z.s each x];
  if[t=98h;:flip .z.s flip x];
  if[t=99h;:$[98h=type key x;(.z.s key x)!.z.s value x;(key x)!.z.s value x]];
  if[t=-11h;:$[null x;(::);x]];
  if[t=11h;:$[any b:null x;{$[y;(::);x]}'[x;b];x]];
  if[(abs t) in key infs;:$[t<0;$[x in infs abs t;(::);x];$[any b:x in infs abs t;{$[y;(::);x]}'[x;b];x]]];
  :x;
  };

/ x in format f
encode:{[f;x] chkformat f; :$[f~`q;x;.j.j jsonable x];};

/ ------------------------------------------------------------------ process facts

/ what the process will bear: the memory cap (-w), physical memory, heap in use, the query
/ timeout (-T, 0 for none) and the policy's result caps. In JSON a cap of 0W is null: no cap
limits:{[p;f]
  w:.Q.w[];
  :encode[f;`memory_cap_bytes`physical_memory_bytes`heap_in_use_bytes`timeout_s`maxrows`maxsize_bytes!
    (w`wmax;w`mphy;w`heap;`long$system"T";p[`config;`maxrows];p[`config;`maxsize])];
  };

/ q's own memory statistics: used, heap, peak, wmax, mmap, mphy, syms, symw
memstats:{[f] :encode[f;.Q.w[]];};

/ who may connect: the policy's users, and its gateway logins
users:{[p;f] :encode[f;([users:rev.users p;gateways:asc p`gateways])];};

/ what a query may call
functions:{[p;f] :encode[f;([functions:asc key p`fns;calls:asc p`calls;joincalls:asc p`joincalls])];};

/ ------------------------------------------------------------------ the rules
/ what a query writer - usually an LLM agent - has to know to write a query qsp will run, one rule
/ per row, following the policy's settings:
/   id       a name for the rule
/   rule     what to do, in one sentence
/   detail   why, and the cases that trip writers up
/   good     queries the rule accepts
/   bad      queries it refuses, or (precedence) that run and give the wrong answer
/   refusal  text a refusal under the rule contains, so a refusal can be matched to its rule
/ the examples are over two tables a query writer will not have - see the first rule. The
/ equities example (examples/equities/hdb.q) runs every one of them, so they stay true

/ one rule; a single string is a list of one
mkrule:{[id;r;d;g;b;rf]
  l:{$[10h=type x;enlist x;x]};
  :`id`rule`detail`good`bad`refusal!(id;r;d;l g;l b;l rf);
  };

ruletable:{[p]
  c:p`config;
  D:"2026.10.09";
  r:enlist mkrule[`language;
    "Send one q-SQL query, as a string: select, exec, update or delete over the tables describe lists.";
    "The query is parsed, never run as text: every part is checked, then it is rewritten to apply your permissions, and only then run. Write q, not SQL - there is no SELECT *, JOIN, GROUP BY, HAVING or ORDER BY: select lists columns separated by commas, names a computed column as name:expression, and groups with by. The examples in these rules use two tables, trades (date, sym, time, price, size) and quotes (date, sym, time, bid, ask), both partitioned by date: use the tables and columns describe gives you instead.";
    ("select from trades where date=",D,", sym=`AAPL";"select vwap:size wavg price by sym from trades where date=",D);
    "SELECT * FROM trades";
    ("qsp: not valid q";"not permitted";"unknown or not-permitted column")];
  r,:enlist mkrule[`precedence;
    "q evaluates right to left: separate where-constraints with commas, not and, and parenthesise what must happen first.";
    "where size>100 and price<5 is read as size>(100 and price<5): it runs, and gives the wrong answer. Commas apply constraints left to right, each narrowing the rows the next sees. Arithmetic is right to left too: 2*price+1 is 2*(price+1), and (2*price)+1 is what most writers mean.";
    ("select from trades where date=",D,", size>100, price<5";"select x:(2*price)+1 from trades where date=",D);
    ("select from trades where date=",D,", size>100 and price<5");
    ()];
  r,:enlist mkrule[`nesting;
    "Put a nested select in parentheses when the outer select has a where of its own: select ... from (select ... where ...) where ....";
    "Without them, the outer where joins the nested select's last constraint: sym=`AAPL where price>100 reads as sym=(`AAPL where price>100), which q cannot run. The same holds for an update over a select.";
    ("select n:count sym from (select sym,price from trades where date=",D,", sym=`AAPL) where price>100");
    ("select n:count sym from select sym,price from trades where date=",D,", sym=`AAPL where price>100");
    "a where after a value"];
  r,:enlist mkrule[`tables;
    "Read only the tables describe lists, and name a table only after from - including a nested select's from.";
    "A table named anywhere else - as a value, as a function's argument, or computed from a string - is refused, as is a table describe does not list.";
    "select n:count sym by date from trades where date within 2026.10.05 2026.10.09";
    ("select from secrets";"count trades");
    ("unknown or non-permissioned table";"can only be used as the table of a select")];
  r,:enlist mkrule[`columns;
    "Name only the columns describe lists for each table; select with no columns returns exactly those.";
    $[c`strictcolumns;"This holds in the where clause as much as the select and by.";
      "A where clause may also test the table's other columns; the select and by may name only the listed ones."],
      " A select over a nested select can name only the columns the nested one returns: name them in the nested select.",
      " A column you name in a nested select and read in the outer one needs a distinctive name: one that is also a name on the server cannot be read back out, and the refusal says so - rename it.",
      " A column you name cannot take the name of a q function - fills, prev, next, rank, xbar and the rest: q will not parse it. A temporal column's parts are read after a dot, as in q: time.minute, time.hh, date.year.";
    ("select date,sym,price from trades where date=",D;"select from trades where date=",D;"select n:count sym by time.minute from trades where date=",D);
    ("select account from trades where date=",D;"select fills:count sym by sym from trades where date=",D);
    ("unknown or not-permitted column";"is not in scope here";"that name is taken on this server";"cannot name a column";"is not a part q takes after a dot")];
  r,:enlist mkrule[`rows;
    "Your row filter is applied for you: you cannot see past it or remove it, and need not repeat it.";
    "describe shows it as a where clause, under rows (\"all rows\" when there is none). The rows it hides do not exist for you: an empty result means no row you may see matches - it is not an error, and retrying will not change it. Your where-constraints run after the filter, so an aggregate such as size=max size is over your rows only. explain shows your query as it would run, with the filter in place.";
    ("select from trades where date=",D);
    ();
    ()];
  if[c`requirepartition;
    r,:enlist mkrule[`partition;
      "On a partitioned table - one with a partition in describe - the first where-constraint must bound the partition column on both sides: date=d, date in d1 d2, or date within d0 d1.";
      "Otherwise every partition would be read, and the query is refused before it runs. A one-sided range such as date>d is not a bound. This applies to every select on such a table, including one nested in another or inside a join. validate finds this without running the query.";
      ("select from trades where date=",D,", sym=`AAPL";"select n:count sym by date from trades where date within 2026.10.05 2026.10.09";"select from trades where date in 2026.10.08 2026.10.09");
      ("select from trades where sym=`AAPL";"select from trades where date>2026.10.05");
      "qsp: full table scan"]];
  if[any not null p`tabs;
    r,:enlist mkrule[`partitioned;
      "On a partitioned table, read with a plain select, and apply exec, select[n] and select[>col] to that: exec sym from select sym from trades where ...";
      "q itself does not implement exec, select[n] or a sorted select directly on a partitioned table, and signals nyi. Over a nested select, which q has already read into memory, they work.";
      ("exec sym from select sym from trades where date=",D;"select[10;>size] from select from trades where date=",D);
      ("exec sym from trades where date=",D;"select[10] from trades where date=",D);
      "qsp: nyi"]];
  if[0W>c`maxpartitions;
    r,:enlist mkrule[`maxpartitions;
      "A query may read at most ",string[c`maxpartitions]," partition",$[1=c`maxpartitions;"";"s"]," of each partitioned table.";
      "The partitions are counted from the constraint on the partition column, before the query runs: validate counts them too. Narrow the range, or ask several queries over smaller ones.";
      ("select from trades where date=",D);
      ();
      "qsp: too many partitions"]];
  r,:enlist mkrule[`comparisons;
    "Compare a column with one value: =, <>, <, >, <= and >= take one value, in takes a list, within a low-high pair, and like one string pattern.";
    "q compares a column with a list item by item: it fails with length, or with as many rows as the list is long quietly pairs them up - use in. Symbols are written with a backtick, `AAPL, and a list of them with no spaces, `AAPL`MSFT. Dates are 2026.10.09, times 09:30:00.000, timestamps 2026.10.09D09:30:00.";
    ("select from trades where date=",D,", sym in `AAPL`MSFT, price within 100 200";"select from trades where date=",D,", sym like \"A*\"");
    ("select from trades where date=",D,", sym=`AAPL`MSFT";"select from trades where date=",D,", price within 100");
    ("takes one value";"within takes two values";"like takes one pattern";"qsp: length";"qsp: type")];
  r,:enlist mkrule[`functions;
    "Use only the functions describe lists under functions, and the named calls under calls - the functions call gives the same two lists on their own.";
    "Lambdas ({...}), assignment (:), system commands, and anything that evaluates text or reaches a file or the network are refused whatever the list says: value, get, eval, parse, system, hopen, set, insert and upsert among them.";
    ("select avg price, max size by sym from trades where date=",D);
    ("select {x+1} price from trades where date=",D;"select from trades where date=",D,", 0<count system \"ls\"");
    ("function not permitted";"is neither a permitted function nor a column";"not valid q")];
  r,:enlist mkrule[`iterators;
    "each, over, scan, prior and peach - and each-left, each-right and each-prior - may apply only q's simple functions: comparison, arithmetic, aggregation, string and set primitives.";
    "A function the query computes cannot be applied at all. To aggregate per group, use by rather than each.";
    ("exec count each group sym from select sym from trades where date=",D);
    ("exec til each 1 2 3 from trades where date=",D);
    ("only q's simple functions can";"function not permitted")];
  r,:enlist mkrule[`symbols;
    "Write table and function names out; never compute one.";
    "q treats a symbol as the name of a global when it applies one, or reads a table by it - `$\"trades\", or a symbol a function returns. Such a symbol is refused. Symbol constants compared with a column, as in sym=`AAPL or sym in `AAPL`MSFT, are data and are fine.";
    ("select from trades where date=",D,", sym=`AAPL");
    ("select (`$\"max\") price from trades where date=",D);
    ("a symbol cannot be";"cannot be applied";"a table name cannot be used as data")];
  r,:enlist mkrule[`functional;
    "Write select, exec, update or delete - not the functional forms ?[t;c;b;a] and ![t;c;b;a].";
    "A functional form runs only when every clause is written as plain data, never as code that builds it, and is easier to get wrong than the select it stands for.";
    ("select sum size by sym from trades where date=",D);
    ("?[trades;enlist(=;`date;",D,");0b;()]");
    ("write the query as select";"can only be used as the table of a select")];
  r,:enlist mkrule[`writes;
    $[c`selectonly;"update and delete must wrap a select - update x:1 from select from t where ... - and change only the copy they return.";
      "update and delete change only the copy they return."],
      " Nothing is ever written to a table.";
    "Use update to add a computed column to a result, and delete to drop columns or rows from it.",
      $[c`selectonly;"";" On a partitioned table, wrap a select anyway: q cannot update one in place."];
    ("update mid:0.5*bid+ask from select from quotes where date=",D);
    $[c`selectonly;enlist "update mid:0.5*bid+ask from quotes where date=",D;()];
    $[c`selectonly;enlist "must wrap a select";()]];
  r,:enlist mkrule[`joins;
    "Join nested selects, each constrained as if it stood alone: aj[`sym`time; select ... from trades where ...; select ... from quotes where ...].";
    "The joins - lj, ij, uj, pj, ej, aj, aj0, wj and wj1, where describe lists them - take a table only as a nested select, never by name. A select over a join can name the columns either side returns. Each side gets its own row filter before they meet. The key columns of aj, aj0, ej, wj and wj1 must be in each side: a side that renames one cannot be joined on it.";
    ("aj[`sym`time; select sym,time,price from trades where date=",D,"; select sym,time,bid,ask from quotes where date=",D,"]");
    ("aj[`sym`time; trades; quotes]";"aj[`sym`time; select sym,time,price from trades where date=",D,"; select sym,t5:time,bid from quotes where date=",D,"]");
    ("can only be used as the table of a select";"a join in the table position must be over nested selects";"to join on")];
  if[not c`rowindex;
    r,:enlist mkrule[`rowindex;
      "The virtual column i, the row index, is not available: count a column instead.";
      "It would show where the rows hidden from you are.";
      ("select n:count sym by date from trades where date=",D);
      ("select n:count i by sym from trades where date=",D);
      "unknown or not-permitted column: i"]];
  r,:enlist mkrule[`sort;
    "To sort or take the first rows, write select[n], select[>col], select[<col] or select[n;>col], or apply xasc or xdesc to a nested select.";
    "select[n] takes the first n rows and select[-n] the last; > sorts descending and < ascending, by a column. On a partitioned table, apply them to a nested select (see partitioned).";
    ("select[10;>size] from select from trades where date=",D;"`price xdesc select from trades where date=",D);
    ();
    ("unsupported sort";"a sort must be by a column")];
  caps:$[0W=c`maxrows;();enlist string[c`maxrows]," rows"],$[0W=c`maxsize;();enlist string[c`maxsize]," bytes"];
  if[count caps;
    r,:enlist mkrule[`results;
      "A result of more than ",(" or " sv caps)," is refused.";
      "The query runs first, so a refused result still cost its work, and validate cannot see it coming - estimate can: it counts the rows before anything runs. Aggregate with by, or narrow with where or select[n], rather than fetching rows to count or sum them yourself.";
      ("select n:count sym, volume:sum size by sym from trades where date=",D;"select[100] from select from trades where date=",D);
      ();
      "result exceeds the maximum permitted"]];
  r,:enlist mkrule[`size;
    "A query that runs longer than the timeout, or needs more memory than the process may use, is stopped.";
    "What counts is its work, not its result: the rows it reads and joins, which estimate counts before anything runs. Narrow its dates and instruments, filter both sides of a join to what the other needs, and aggregate before joining rather than after.";
    ("select n:count sym, volume:sum size by sym from trades where date=",D);
    ();
    ("ran longer than the timeout";"needed more memory")];
  r,:enlist mkrule[`depth;
    "An expression may nest at most ",string[c`maxdepth]," levels deep.";
    "Nesting counts each function application, bracket and nested select. Split a deep expression into simpler parts, or several queries.";
    ();
    ();
    "nested too deeply"];
  r,:enlist mkrule[`refusals;
    "A refusal is an error whose message starts qsp: and names what was refused: change that part and send the query again.";
    "The same query is refused the same way every time, so retrying it unchanged is pointless. Each rule's refusal lists text its refusals contain: the rule whose text the message contains explains it, and its good examples show the fix. validate makes every check that does not need the query to run, so it catches most refusals without running anything; explain shows what would run. \"qsp: not valid q (...)\" means q could not parse the text. Any other message - type, length, rank - is q itself failing to evaluate what qsp let through: check the types and shapes of what the query combines.";
    ();
    ();
    "qsp: "];
  :r;
  };

/ the rules a query writer has to know, as a table: see ruletable
rules:{[p;f] :encode[f;ruletable p];};

/ primer.md, beside this file: how to write q that qsp accepts - a method, the q that matters,
/ the shapes qsp takes, time-series techniques, and what a refusal means - as one markdown text
/ for an agent to hold in context before it writes its first query. The rules say what qsp
/ refuses; the primer says how to get an answer within them. It is the same for every policy and
/ user, and read on every call, like the admin UI's page. Every q example in it is a query qsp
/ accepts: the equities example's walkthrough (hdb.q) runs each one
mark:{[] };
primerfile:{[f] :hsym`$((1+last where f="/")#f),"primer.md";} first -3#value mark;
primer:{[f] :encode[f;"\n" sv read0 primerfile];};

/ ------------------------------------------------------------------ per user

/ q's type of each type character a schema holds, by name; a capital is a list of that type in
/ each row (a string column is char[]), and a blank is a type the policy does not know
typenames:" bgxhijefcspmdznuvt"!``boolean`guid`byte`short`int`long`real`float`char`symbol`timestamp`month`date`datetime`timespan`minute`second`time;
typename:{[c] :$[null c;`;c in key typenames;typenames c;(lower c) in key typenames;`$string[typenames lower c],"[]";`$enlist c];};

/ the type of each of columns c on table t
types:{[p;t;c] :typename each (exec col!typ from p[`schema] where tbl=t) c;};

chkuser:{[p;u] tree.chk[rev.isuser[p;u];"not a user of this policy: ",-3!u];};

/ what user u can read: per table, the columns and the rows (review.access)
access:{[p;u;f] chkuser[p;u]; :encode[f;rev.access[p;u]];};

/ the business's terms whose tables can all be read from ts, with their tables as `tables`
termsfor:{[p;ts]
  t:$[`terms in key p;p`terms;pol.emptyterms];
  t:t where all each t[`tbls] in\: ts;
  if[not `params in cols t;t:update params:(count t)#enlist "",example:(count t)#enlist "" from t];
  :flip `term`meaning`formula`q`tables`caveat`params`example!t`term`meaning`formula`q`tbls`caveat`params`example;
  };

/ everything a query writer needs, as one dictionary: the tables user u may read (tabs: their
/ granted columns, in the table's order, with q type names, bytes per row and descriptions, the
/ partition column and the row filter as a where clause), the functions and calls permitted, the
/ limits, and the rules
describe:{[p;u;f]
  chkuser[p;u];
  a:rev.access[p;u];
  / computed first: q-sql resolves a module's names in the caller's namespace
  ty:types[p]'[a`tbl;a`columns];
  pc:p[`tabs]a`tbl;
  / each granted column's bytes per row (0n where not measured) and description ("" where none):
  / the columns the user may not read are never described
  ci:pol.colinfofor[p]'[a`tbl;a`columns];
  t:select tbl,partition:pc,columns,types:ty,bytes:ci[;0],descriptions:ci[;1],rows from a;
  :encode[f;([user:u;tabs:t;functions:asc key p`fns;calls:asc p`calls;
    / the limits a query writer may know: the policy's, and the process's timeout (-T) and
    / memory cap (-w, 0 for none). Physical memory and the heap stay with gateways (limits)
    limits:((`maxrows`maxsize`maxdepth`requirepartition`maxpartitions`strictcolumns`rowindex`selectonly)#p`config),
      `timeout_s`memory_cap_bytes!(`long$system"T";.Q.w[]`wmax);
    rules:ruletable p;
    / the business's terms whose tables this user can read
    terms:termsfor[p;a`tbl];
    / may this user save results out of the database - to a workspace, a file, another tool?
    / The policy decides; whatever writes the file enforces it
    export:pol.ingroup[p;p[`config;`exportgroup];u]])];
  };

export:([formats;encode;limits;memstats;users;functions;rules;primer;access;describe;termsfor]);
