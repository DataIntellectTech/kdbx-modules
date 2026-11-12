/ di.qsp.review - what a policy means, for the people who approve it
/   access[p;u]   what user u can read: per table, the columns and the rows
/   diff[a;b]     what changes for whom when policy a is replaced by b
/ reviewing a policy file line by line answers "what did the author type"; these answer "who can
/ now see what", which is the question an approver is actually being asked. Row filters are
/ written back as q where clauses, in the same form a grants.csv filter cell takes
/ a lambda filter is called, for each user, as it would be on a query: the answer is as of now. A
/ lambda that signals shows as "refused: ...", which is what that user's queries would get

tree:use`..tree;
fns:use`..fns;
pol:use`..policy;

/ ------------------------------------------------------------------ rendering

/ operators written between their arguments
infixnames:`in`within`like`and`or`mod`div`xbar`except`inter`union`bin`binr`xexp`xlog`wavg`wsum;
infix:{[n] :(n in infixnames)or all (string n) in "=<>~&|+-*%#_,!?$^@.";};

/ parse writes a<>b, a<=b and a>=b with a composition of not and another operator in the head: a
/ parse tree of its own, not a function value
composed:`$("<>";"<=";">=");
ctrees:{first parse "a",x,"b"} each string composed;

fname:{[p;x]
  / a function value -> its name in the policy's whitelist
  if[x~fns.notsafe;:`not];
  if[(count k:key p`fns)>i:(value p`fns)?x;:k i];
  if[not null n:fns.name x;:n];
  :`$-3!x;
  };

/ a literal, as q text - a whole-second timespan without its nanoseconds
lit:{[x] s:-3!x; :$[(-16h=type x)and s like "*.000000000";-10_s;s];};

textsym:{[u;x]
  / a name, or a marker: u is the user qsp.USER stands for; ` leaves the marker in
  if[x~tree.usermark;:$[null u;"qsp.USER";-3!u]];
  if[x~tree.nowmark;:"qsp.NOW"];
  :string x;
  };

/ a symbol constant; or names side by side - a call
textsyms:{[p;u;x] :$[1=count x;-3!first x;string[first x],"[",(";"sv text[p;u] each 1_x),"]"];};

/ an argument of an infix or prefix operator, parenthesised if it is itself an application
argtext:{[p;u;y] s:text[p;u;y]; :$[(0h=type y)and 1<count y;"(",s,")";s];};

/ is x the aged form (<;c;(agedmark;c;span)), which reads back as qsp.aged[c;span]?
isaged:{[x] :(3=count x)and(0h=type x 2)and tree.agedmark~first x 2;};

text:{[p;u;x]
  / a constraint (or any parse tree) -> q text. u is the user qsp.USER stands for; ` leaves the
  / marker in
  if[-11h=type x;:textsym[u;x]];
  if[11h=type x;:textsyms[p;u;x]];
  if[0h<>type x;:lit x];
  if[0=count x;:"()"];
  / a symbol vector constant
  if[(1=count x)and 11h=type first x;:-3!first x];
  if[isaged x;:"qsp.aged[",string[x[2;1]],";",(lit x[2;2]),"]"];
  h:first x;
  a:1_x;
  if[h~enlist;:-3!$[1=count a;first a;a]];
  if[(0h=type h)and count i:where ctrees~\:h;h:composed first i];
  if[0h=type h;:"(",text[p;u;h],")[",(";"sv text[p;u] each a),"]"];
  n:$[-11h=type h;h;fname[p;h]];
  if[(2=count a)and infix n;:(argtext[p;u;a 0])," ",string[n]," ",argtext[p;u;a 1]];
  if[(1=count a)and n=`not;:"not ",argtext[p;u;a 0]];
  :string[n],"[",(";"sv text[p;u] each a),"]";
  };

/ a whole row filter -> one where clause
clause:{[p;u;f] :$[0=count f;"all rows";", "sv text[p;u] each f];};

/ ------------------------------------------------------------------ access

/ everyone a policy names who is not a group: users in groups, and entities granted something
/ directly
users:{[p] :asc (distinct p[`members;`user],p[`grants;`entity]) except p[`members;`entity];};

/ user u's row filter on t, as a where clause
rowstext:{[p;u;t] :clause[p;u] pol.rawfilter[p;u;t];};

state:{[p;u;t]
  / (columns;rows) for user u on table t; rows is "" when there is no access
  if[0=count c:pol.columnsfor[p;u;t];:(`symbol$();"")];
  r:@[rowstext[p;u];t;{"refused: ",tree.clean x}];
  :(c;r);
  };

/ the entities whose grants give user u table t
via:{[p;u;t] :exec entity from pol.grantsfor[p;u;t];};

accessfor:{[p;u]
  / access rows for one user
  ts:key p`tabs;
  s:state[p;u] each ts;
  k:where 0<count each first each s;
  :([]user:(count k)#u;tbl:ts k;columns:s[k;0];rows:s[k;1];via:via[p;u] each ts k);
  };

access:{[p;us]
  / what user us (or each of a list; ` for everyone) can read under policy p. via is the
  / entities whose grants give it to them
  us:$[us~`;users p;(),us];
  r:raze accessfor[p] each us;
  :$[count r;r;([]user:`symbol$();tbl:`symbol$();columns:();rows:();via:())];
  };

/ ------------------------------------------------------------------ diff

nodiff:([]user:`symbol$();tbl:`symbol$();change:`symbol$();detail:());

plusminus:{[was;now] :" "sv ("+",/:string now except was),"-",/:string was except now;};

diffrow:{[u;t;c;d] :([]user:enlist u;tbl:enlist t;change:enlist c;detail:enlist d);};

diffone:{[a;b;u;t]
  / what changes for one user on one table
  x:state[a;u;t];
  y:state[b;u;t];
  if[x~y;:nodiff];
  if[0=count x 0;:diffrow[u;t;`gains;(" "sv string y 0)," | ",y 1]];
  if[0=count y 0;:diffrow[u;t;`loses;(" "sv string x 0)," | ",x 1]];
  r:nodiff;
  if[not (asc x 0)~asc y 0;r,:diffrow[u;t;`columns;plusminus[x 0;y 0]]];
  if[not x[1]~y 1;r,:diffrow[u;t;`rows;x[1]," -> ",y 1]];
  :r;
  };

/ a policy-wide change: it has no user or table
widerow:{[c;d] :diffrow[`;`;c;d];};
configchange:{[a;b;k] :widerow[`config;string[k],": ",(-3!a[`config;k])," -> ",-3!b[`config;k]];};

diffwide:{[a;b]
  / policy-wide: settings, gateways, whitelisted and callable functions
  ks:distinct key[a`config],key b`config;
  r:nodiff,raze configchange[a;b] each ks where not a[`config;ks]~'b[`config;ks];
  if[count d:plusminus[a`gateways;b`gateways];r,:widerow[`gateways;d]];
  if[count d:plusminus[key a`fns;key b`fns];r,:widerow[`functions;d]];
  if[count d:plusminus[a`calls;b`calls];r,:widerow[`calls;d]];
  if[count d:plusminus[a`joincalls;b`joincalls];r,:widerow[`joincalls;d]];
  :r;
  };

/ what changes for user u, on each of tables ts
diffuser:{[a;b;ts;u] :raze diffone[a;b;u] each ts;};

diff:{[a;b]
  / what changes when policy a is replaced by policy b: one row per change
  /   gains / loses   a user can now / can no longer read a table
  /   columns         +col visible now, -col no longer
  /   rows            the row filter, before -> after
  /   config gateways functions calls joincalls   policy-wide (user is `)
  / gateway changes matter most: a gateway login may act as any user
  us:asc distinct users[a],users b;
  ts:asc distinct key[a`tabs],key b`tabs;
  :diffwide[a;b],raze diffuser[a;b;ts] each us;
  };

export:([access;diff;users;text;clause]);
