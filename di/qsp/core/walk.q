/ di.qsp.core.walk - check every node of a parse tree, and rewrite it
/   walk[c;scope;depth;node] -> (rewritten node; column names it projects)
/ c is the context of one rewrite (see ctx); scope is the set of names a bare symbol may legally
/ reference at this point. Every node must be explicitly permitted. Anything not understood is
/ refused, so q syntax this walker has never seen fails closed
/   function value      must be on the whitelist, by identity
/   symbol atom         a name reference - must be a column in scope
/   symbol vector, 2+   q evaluates `f`a`b as a call, so it is checked as one
/   general list        an application: head permitted, args walked
/   select/exec/...     the table slot pinned to the caller's grants
/   anything else       literal data
/ for every select whose table slot is a registered table, the policy's row filter is placed into
/ the where clause (order.q) and "select *" becomes an explicit projection of exactly the granted
/ columns

tree:use`..tree;
fns:use`..fns;
pol:use`...policy;
ord:use`..order;

nocols:`symbol$();
gone:`$"\001qsp.gone";

/ the context of one rewrite: the policy, the user, and what is worth computing once - the
/ whitelist's values, and which tables the query reads
ctx:{[p;u;q] :([p;u;cfg:p`config;fv:value p`fns;reads:tree.basetables q]);};

fnok:{[c;x] :(count c`fv)>(c`fv)?x;};

fnstr:{[c;x]
  / a function value, named for a refusal
  if[not tree.isfn x;:"<not a function>"];
  :$[(count c`fv)>i:(c`fv)?x;string (key c[`p;`fns])i;not null n:fns.name x;string n;"<unnamed>"];
  };

cols4:{[c;t] :pol.columnsfor[c`p;c`u;t];};
istable:{[c;n] :n in key c[`p;`tabs];};

/ a column the caller holds on a table this query reads. Not being in scope is then not a
/ permission decision - the grant is there, and the name did not survive the expression it is
/ being read out of - and saying so sends the reader somewhere other than the grants
granted:{[c;n] :any n in/: cols4[c] each c`reads;};

notinscope:{[c;n]
  / refuse a name that is not in scope, saying why
  tree.chk[not istable[c;n];string[n]," can only be used as the table of a select, not as a value"];
  if[granted[c;n];tree.fault string[n]," is not in scope here - the inner select/update does not project it"];
  tree.chk[0b;"unknown or not-permitted column: ",string n];
  };

headsym:{[c;scope;h]
  / a symbol at the head of a list is either a call - eval applies it to the rest - or a column
  / being indexed: "price where size>100" parses as (`price;(&:;...)). The call list wins where
  / both could apply
  if[h in c[`p;`calls];:h];
  if[h in scope;:h];
  tree.chk[not istable[c;h];string[h]," can only be used as the table of a select, not as a value"];
  if[granted[c;h];tree.fault string[h]," is not in scope here - the inner select/update does not project it"];
  tree.chk[0b;string[h]," is neither a permitted function nor a column in scope"];
  };

/ a registered table's name is refused as data too. parse enlist-wraps a symbol literal, and
/ xasc, xdesc, xcol and xcols all mutate the table whose name they are handed: `sym xasc `trade
/ sorts the real table in place
hastable:{[c;x] :$[11h=abs type x;any x in key c[`p;`tabs];(type x) in 0 98 99h;any hastable[c] each tree.items x;0b];};

/ a function inside literal data. eval hands back the item of a one-item list unevaluated -
/ that is how a tree quotes a value - so (each;enlist value;...) would apply value without its
/ ever being walked as a function. parse never quotes a function, so any is refused
hasfn:{[x] :$[tree.isfn x;1b;0h=type x;any .z.s each x;98h=type x;.z.s value flip x;99h=type x;.z.s[key x]|.z.s value x;0b];};

literal:{[c;n]
  / literal data, projecting nothing
  tree.chk[not hastable[c;n];"a table name cannot be used as data, only as the table of a select"];
  tree.chk[not hasfn n;"a function cannot be written as data - apply it, or pass it where it is applied"];
  :(n;nocols);
  };

/ ------------------------------------------------------------------ what an expression projects
/ the walker hands a select's table slot the names an expression projects, and the query above
/ may then name them. A name the result does not really carry is not simply lost - q resolves it
/ globally, and on a partitioned HDB `sym` is the enum domain holding every symbol in the
/ database. So the children's columns are handed on only by heads known to keep their table
/ argument's column set; a column take names its own; every other head projects nothing, and is
/ refused in the table slot rather than guessed at

tryresolve:{[n] :@[fns.resolve;n;(::)];};
/ ! is not among them: `a`b!t is a dictionary of t's rows, not a table (see keyedcols)
preserve:{x where not (::)~/:x} tryresolve each `xasc`xdesc`xcols`asc`desc`reverse`distinct`ungroup`sublist;
if[9>count preserve;'"qsp: cannot resolve q's own sort and key primitives - refusing to load"];
takeop:@[fns.resolve;`$"#";{gone}];
dropop:@[fns.resolve;`$"_";{gone}];
dictop:@[fns.resolve;`$"!";{gone}];

litsyms:{[x] :$[(0h=type x)&(1=count x)&11h=type first x;(),first x;`symbol$()];};
takelit:{[x] :$[11h=abs type x;(),x;litsyms x];};
nonsymlit:{[x] :(0h<>type x)and not 11h=abs type x;};

/ `a`b#t names its columns; 3#t takes rows and keeps every column; a computed left argument
/ could turn out to be either, so it projects nothing
takecols:{[a;cs] :$[count s:takelit a;cs inter s;nonsymlit a;cs;nocols];};
dropcols:{[a;cs] :$[count s:takelit a;cs except s;nonsymlit a;cs;nocols];};

/ x!y is a keyed table when x is a count of key columns - 1!t - or a table of keys - k!v - and
/ then carries the columns of its table arguments. With anything else on the left, `a`b!t say,
/ it is a dictionary, and a name looked up in it would resolve globally
keyedcols:{[a;cs]
  if[2<>count a;:nocols];
  if[all 0<count each cs;:distinct raze cs];
  if[(type first a) in -5 -6 -7h;:cs 1];
  :nocols;
  };

/ is h a call the policy says carries its arguments' columns?
isjoincall:{[c;h] :$[-11h=type h;h in c[`p;`joincalls];0b];};

exprcols:{[c;h;a;cs]
  / the columns head h applied to arguments a projects, given the columns cs each argument does
  if[h~dictop;:keyedcols[a;cs]];
  cs:distinct raze cs;
  if[any h~/:tree.joins;:cs];
  if[isjoincall[c;h];:cs];
  if[h~takeop;:$[2=count a;takecols[first a;cs];nocols]];
  if[h~dropop;:$[2=count a;dropcols[first a;cs];nocols]];
  if[any h~/:preserve;:cs];
  :nocols;
  };

safename:{[c;n]
  / a second guard behind exprcols: a projected name that shadows a global the caller was not
  / granted is dropped from the scope handed on, so a table expression can never be used to name
  / the caller's own alias for a process function
  / ("select r:allowedsyms[`u] from meta select allowedsyms:size ...")
  v:@[value;n;gone];
  if[gone~v;:1b];
  if[tree.isfn v;:fnok[c;v]];
  :granted[c;n];
  };

pivotcols:{[l]
  / a dictionary-bodied exec pivots - exec `a`b#k!v by x - and returns the by-columns plus the
  / dictionary's keys, which are knowable only when they are a literal symbol list in the tree
  if[1<>count l;:nocols];
  if[0h<>type e:first l;:nocols];
  if[3<>count e;:nocols];
  if[not any (first e)~/:(takeop;dictop);:nocols];
  :litsyms e 1;
  };

/ ------------------------------------------------------------------ the walk

walk:{[c;scope;depth;n]
  / one node -> (rewritten node; column names it projects); see the top of this file
  tree.chk[depth<=c[`cfg;`maxdepth];"expression is nested too deeply"];
  if[tree.isquery n;:query[c;scope;depth;n]];
  t:type n;
  if[tree.isfn n;:walkfn[c;n]];
  if[t=-11h;:walksym[c;scope;n]];
  if[(t=11h)&1<count n;:walkcall[c;scope;depth;n]];
  tree.chk[t<>99h;"dictionary expressions are not permitted here"];
  if[t=0h;:walklist[c;scope;depth;n]];
  :literal[c;n];
  };

walkfn:{[c;n]
  / a function value: whitelisted, and swapped for its guarded wrapper if it has one
  tree.chk[fnok[c;n];"function not permitted: ",fnstr[c;n]];
  :(fns.subst n;nocols);
  };

/ a symbol atom is a name reference, never data
walksym:{[c;scope;n] if[not n in scope;notinscope[c;n]]; :(n;nocols);};

walkcall:{[c;scope;depth;n]
  / a bare symbol vector is a name call. parse never emits one - it enlist-wraps symbol
  / literals - but a hand-built tree sent over IPC can
  h:first n;
  tree.chk[h in c[`p;`calls];"call to ",string[h]," is not permitted"];
  r:walk[c;scope;depth+1;] each 1_n;
  :($[all r[;0]~'1_n;n;(enlist h),r[;0]];nocols);
  };

walkhead:{[c;scope;depth;h]
  / the head of an application: usually a function value, but q renders <>, <= and >= as a
  / composition, which is an expression in its own right
  if[-11h=type h;:headsym[c;scope;h]];
  if[tree.isfn h;:first walkfn[c;h]];
  if[0h=type h;:first walk[c;scope;depth+1;h]];
  tree.chk[0b;"expression head is not a permitted function: ",fnstr[c;h]];
  };

walklist:{[c;scope;depth;n]
  / a general list: an application, head permitted and arguments walked
  / () and one-item lists are literal data - (enlist x) is "x, verbatim"
  if[2>count n;:literal[c;n]];
  h:first n;
  h2:walkhead[c;scope;depth;h];
  r:walk[c;scope;depth+1;] each 1_n;
  g:guarded[c;h;h2;r[;0]];
  / rebuild only if something changed: amending a general list of symbols would collapse it into
  / a symbol vector, which q evaluates differently
  :($[(g[0]~h)&all g[1]~'1_n;n;(enlist g 0),g 1];exprcols[c;h2;1_n;r[;1]]);
  };

/ ------------------------------------------------------------------ symbols resolved at run time
/ q resolves a symbol atom as a global's name wherever it is applied, or handed to a function that
/ reads a table by name (see fns.q). Every name written in the tree is checked above; these check
/ the symbols a query computes. An argument is left alone where the function never resolves one,
/ refused if it is a literal symbol where one would be resolved, and otherwise wrapped in a check
/ that runs on the value as it is produced

/ a quoted symbol: what parse writes, (enlist `a), or a general list holding one, which a
/ hand-built tree can
issymlit:{[x] :$[11h=type x;1=count x;(0h=type x)&1=count x;-11h=type first x;0b];};

inert:{[x]
  / is x certainly not a symbol atom once evaluated? A function, a name the walker has already
  / checked, literal data other than a symbol, or a select - which returns a table. A policy call,
  / or an exec, can return anything
  if[tree.isfn x;:1b];
  if[-11h=type x;:1b];
  if[tree.isquery x;:not ()~x 3];
  / a one-item list is its item, verbatim, and literal has refused a function in it
  if[0h=type x;:$[1=count x;not -11h=type first x;0b]];
  :not 11h=type x;
  };

checks:`data`fn`cast!(fns.nosym;fns.fnarg;fns.castarg);

guard:{[c;rule;f;x]
  / argument x of a call to f, checked by rule (fns.rules)
  if[rule=`none;:x];
  if[rule=`fby;:fbyguard[c;f;x]];
  if[rule=`wjagg;:$[wjstatic[c;f;x];x;(fns.wjagg;x)]];
  chk:checks rule;
  if[issymlit x;@[chk;first x;{[f;e] 'e," (passed to ",f,")"}fnstr[c;f]];:x];
  if[rule=`fn;:fnguard[c;f;x]];
  :$[inert x;x;(chk;x)];
  };

/ literal data in a tree: an atom or vector other than a symbol one, or anything quoted in a
/ one-item list. Its value is known as the tree is walked
isliteral:{[x] :$[0h=type x;2>count x;not (11h=abs type x)|tree.isfn x];};
litvalue:{[x] :$[0h<>type x;x;1=count x;first x;x];};

fnguard:{[c;f;x]
  / an argument q applies. "Not a symbol" is not enough here: 0 each enlist "text" applies handle
  / 0, which evaluates the text, and (each;count) indexed at depth applies each. A function and
  / literal data are checked as the tree is walked; a call the policy trusts is left alone; a
  / column, or anything computed, is checked as it runs
  if[tree.isfn x;
    tree.chk[fns.ispure x;fnstr[c;x]," cannot be applied by ",fnstr[c;f]," - only q's simple functions can"];
    :x];
  if[isliteral x;@[fns.fnarg;litvalue x;{[f;e] 'e," (passed to ",f,")"}fnstr[c;f]];:x];
  if[$[-11h=type x;x in c[`p;`calls];0b];:x];
  :(fns.fnarg;x);
  };

/ a literal (function;column) pair, as parse leaves (max;size): (enlist;max;`size)
ispair:{[x] :(0h=type x)&(2<=count x)&(first x)~enlist;};

fbyguard:{[c;f;x]
  / fby's (function;column): checked here when written out, or as it runs
  if[not ispair x;:(fns.fbyarg;x)];
  g:guard[c;`fn;f;x 1];
  :$[g~x 1;x;@[x;1;:;g]];
  };

wjstatic:{[c;f;x]
  / is wj's aggregation list written out, and each function in it checked here?
  if[not ispair x;:0b];
  if[not all ispair each 1_1_x;:0b];
  {[c;f;x] guard[c;`fn;f;x 1]}[c;f] each 1_1_x;
  :all inert each {x 1} each 1_1_x;
  };

guarded:{[c;h;h2;a]
  / (head;arguments) of an application, with every symbol q could resolve as a global name checked
  if[tree.isfn h;
    if[(h~fns.findop)&2=count a;:(fns.findsafe;a)];
    :(h2;guard[c;;h;]'[fns.rules[h;count a];a])];
  / a call the policy trusts; or a column, indexed by the arguments - and checked as it runs, as
  / a column of functions applies the one it reaches: f[0;g;y] over select f:(each;count)
  if[-11h=type h;:$[h in c[`p;`calls];(h2;a);((fns.fnarg;h2);a)]];
  / an expression in the head: what q applies is only known when it runs
  tree.chk[not issymlit h2;"`",string[first h2]," cannot be applied - q would call the global it names"];
  if[isderived h2;:(h2;$[3=count h2;a;guard[c;`data;first h2;] each a])];
  :((fns.fnarg;h2);a);
  };

/ (';f) derives f each, which applies f and resolves a symbol atom it is applied to. (';f;g) is f
/ composed with g, whose parts have been checked as functions
isderived:{[x] :(0h=type x)&(count[x] within 2 3)&fns.isiter first x;};

walkall:{[c;scope;depth;l]
  / walk a list of expressions, keeping the container
  if[0=count l;:(l;nocols)];
  r:walk[c;scope;depth+1;] each l;
  :($[all r[;0]~'l;l;r[;0]];distinct raze r[;1]);
  };

/ ------------------------------------------------------------------ queries

/ a functional form written as text - ?[t;enlist(=;`a;1);0b;()] - parses with its clauses as code
/ that builds them as the query runs: (enlist;(enlist;=;,`a;1)), where select text gives the
/ clause itself, ,,(=;`a;1). The walker checks a clause as written, and q would run what the code
/ builds - ?[t;();0b;(enlist`x)!enlist(distinct;`hidden)] read a column the caller was not
/ granted. So each clause must have the shape parse gives select text. A functional form whose
/ arguments are plain data, ?[t;();0b;()], parses to exactly that shape, and runs
funcform:"write the query as select, exec, update or delete - a functional form's clauses must be data, not code that builds them";

/ where: () or, as parse writes it, a one-item list holding the list of constraints
iswhere:{[s] :$[s~();1b;0h<>type s;0b;tree.cnested;(1=count s)&0h=type first s;1b];};

/ the table slot: a table name, or an expression - a nested select, a join of nested selects, a
/ sort or unkey of one. Each returns ([base;tn;vcols;slot]): whether it is a table name, the name,
/ the columns visible through it, and the rewritten slot

tableslot:{[c;depth;isupd;ts]
  tree.chk[11h<>type ts;"in-place update/delete is not permitted"];
  :$[-11h=type ts;basetable[c;isupd;ts];exprtable[c;depth;ts]];
  };

basetable:{[c;isupd;tn]
  / a registered table, read through the caller's grants
  tree.chk[not isupd and c[`cfg;`selectonly];"update/delete must wrap a select statement, not a table"];
  tree.chk[istable[c;tn];"unknown or non-permissioned table: ",string tn];
  / q signals 'par for an update or delete on a partitioned table, and over the select it would
  / wrap here, its where clause could not prune: every partition would be read
  tree.chk[not isupd and not null c[`p;`tabs;tn];
    "update/delete on a partitioned table must wrap a select - update ... from select from ",string[tn]," where ..."];
  tree.chk[0<count vcols:cols4[c;tn];"no column access granted on table: ",string tn];
  :([base:1b;tn:tn;vcols:vcols;slot:tn]);
  };

exprtable:{[c;depth;ts]
  / an expression, walked with no scope: it is evaluated before any column is bound, so a column
  / name means nothing there. Every read underneath is pinned to the caller's grants before the
  / expression runs, so nothing new can become visible
  tree.chk[0h=type ts;"unsupported table expression - expected a table name or a nested select"];
  r:walk[c;nocols;depth+1;ts];
  vcols:(r 1) where safename[c] each r 1;
  tree.chk[tree.isquery[ts]|0<count vcols;exprerror ts];
  :([base:0b;tn:`;vcols:vcols;slot:r 0]);
  };

exprerror:{[ts]
  / why a table expression projects nothing a select can name
  :$[tree.isjoin ts;"a join in the table position must be over nested selects";
    tree.hasquery ts;"the columns this expression projects cannot be known before it runs - read from the select itself";
    "a table expression must be over a nested select"];
  };

byclause:{[c;outscope;depth;b]
  / the by slot -> (rewritten slot; by columns; is it a bare list of names). It is 0b (none), 1b
  / (select distinct), () (exec, no by), a dictionary, or - for "exec ... by sym" - a bare list
  / of names, which q answers with a dictionary rather than a keyed table, so it is checked name
  / by name and left in the form it was written
  names:(0h=type b)and(0<count b)and all -11h=type each b;
  if[names;walkall[c;outscope;depth;b];:(b;`symbol$b;1b)];
  if[99h=type b;tree.chk[names4 key b;funcform];:((key b)!first walkall[c;outscope;depth;value b];key b;0b)];
  tree.chk[(b~0b)|(b~1b)|b~();$[0h=type b;funcform;"unsupported by clause"]];
  :(b;nocols;0b);
  };

/ the names a by or select dictionary gives its columns: one or more symbols, none null. q reads
/ an empty one as "every column", which select * pins and this would not
names4:{[k] :(11h=type k)and(0<count k)and not any null k;};

/ the select slot -> (rewritten slot; columns it outputs). s holds what the other slots
/ established: isupd, base, vcols, a (the select slot), byslot, bycols, names and istab (not an exec
/ without by)

selectclause:{[c;outscope;depth;s]
  a:s`a;
  if[99h=type a;:selectdict[c;outscope;depth;s]];
  if[a~();:selectstar s];
  / delete rows: q reads an empty symbol list as every column, so only a delete may have one
  if[11h=type a;tree.chk[(s`isupd)and(0=count a)and 0b~s`byslot;funcform];:(a;s`vcols)];
  / delete columns. In an exec the same shape is a call, `f`col, walked as one below
  if[(s`isupd)and(0h=type a)and(1=count a)and 11h=type first a;
    tree.chk[0b~s`byslot;funcform];
    walksym[c;s`vcols] each first a;
    :(a;(s`vcols) except first a)];
  / an exec's expression, quoted in a one-item list
  if[0h=type a;tree.chk[1=count a;funcform];:execlist[c;outscope;depth;s]];
  tree.chk[0b;"unsupported select/update/delete expression"];
  };

selectdict:{[c;outscope;depth;s]
  / named columns. An update keeps its input's columns and adds the assigned ones. A select is
  / a table, keyed by its by; an exec only with a named by - exec a:x by s:sym - and with a bare
  / one, exec a:x by sym, it is a dictionary keyed by sym's values
  tree.chk[names4 key s`a;funcform];
  a:(key s`a)!first walkall[c;outscope;depth;value s`a];
  vcols:s`vcols;
  bycols:s`bycols;
  :(a;$[s`isupd;vcols,(key a) except vcols;(s`istab)and not s`names;bycols,(key a) except bycols;nocols]);
  };

/ the last of each of columns vc, as a by-select * takes them
lastof:{[vc] :vc!{((last);x)} each vc;};

selectstar:{[s]
  / "select *": pinned to exactly the columns this user may see
  tree.chk[not s`isupd;"unsupported update/delete expression"];
  tree.chk[s[`istab] and not s`names;"unsupported exec expression"];
  vcols:s`vcols;
  bycols:s`bycols;
  keyed:99h=type s`byslot;
  / grouped by every column there is nothing left to take the last of, and q itself signals rank
  / (select by a,b from ([]a;b)). Say so, rather than pass on a bare rank
  if[s[`base]and keyed;tree.chk[count vcols except bycols;
    "select * grouped by every column you can see returns no columns, which q refuses - aggregate a column (select n:count c by ...) or use select distinct"]];
  a:$[not s`base;();keyed;lastof vcols except bycols;vcols!vcols];
  :(a;$[keyed;bycols,vcols except bycols;vcols]);
  };

execlist:{[c;outscope;depth;s]
  / an exec expression list
  pv:pivotcols s`a;
  a:first walkall[c;outscope;depth;s`a];
  / a table only when it pivots, by a named by, into columns the tree names: any other exec
  / gives a list or a dictionary
  :(a;$[(s`istab)and(not s`names)and 0<count pv;(s`bycols),pv except s`bycols;nocols]);
  };

/ select[n;<c]: parse adds a limit slot, and a sort slot (enlist (grade;expression)). q evaluates
/ both. The sort is applied to the rows the select reads, or with a by to the rows it returns, and
/ a name that table lacks resolves to a global - so the sort is walked in exactly that table's
/ columns, and its grade is swapped for one that only sorts (fns.ascsafe)

sortbad:"unsupported sort - write select[<col] or select[>col]";

sortslot:{[c;scope;depth;s]
  / the sort slot -> rewritten
  tree.chk[(0h=type s)and 1=count s;sortbad];
  o:first s;
  tree.chk[(0h=type o)and 2=count o;sortbad];
  i:(tree.ascop;tree.descop)?o 0;
  tree.chk[i<2;sortbad];
  :enlist ((fns.ascsafe;fns.descsafe) i;first walk[c;scope;depth+1;o 1]);
  };

extras:{[c;depth;s;out;x]
  / the slots after the select slot: x is (limit) or (limit;sort). The limit names no column. s
  / and out are what selectclause had and gave
  tree.chk[(not s`isupd)and 2>=count x;"unsupported select/update/delete expression"];
  n:first walk[c;nocols;depth+1;first x];
  if[1=count x;:enlist n];
  / a plain select sorts what it reads; with a by, what it returns. exec, and select distinct (nyi
  / in q), are refused
  b:s`byslot;
  tree.chk[s[`istab]and(b~0b)or 99h=type b;"a sort is only supported on select, without distinct"];
  :(n;sortslot[c;$[99h=type b;out;s`vcols];depth;x 1]);
  };

query:{[c;scope;depth;q]
  / a select/exec/update/delete: the table slot pinned to the caller's grants, the policy's row
  / filter placed into the where clause, and "select *" made explicit
  isupd:q[0]~tree.updop;
  tree.chk[iswhere q 2;funcform];
  ts:tableslot[c;depth;isupd;q 1];
  base:ts`base;
  vcols:ts`vcols;
  / where may see every real column if strictcolumns is off; by and select produce output and are
  / always limited to the granted columns
  / ...but not an update or delete's: it runs over the pinned select, which holds only the
  / granted columns, and a name it lacks resolves to a global
  refcols:$[base and (not isupd) and not c[`cfg;`strictcolumns];pol.columnsof[c`p;ts`tn];vcols];
  outscope:vcols,$[c[`cfg;`rowindex];enlist`i;nocols];
  w:first walkall[c;refcols;depth;tree.getc q 2];
  if[base;w:ord.guardvalues[pol.info[c`p;ts`tn];w]];
  bc:byclause[c;outscope;depth;q 3];
  s:([isupd;base;vcols;a:q 4;byslot:bc 0;bycols:bc 1;names:bc 2;istab:not (q 3)~()]);
  sc:selectclause[c;outscope;depth;s];
  pf:$[base;pol.filterfor[c`p;c`u;ts`tn];()];
  / an update/delete runs over a select pinned to the grants; a select gets the filter in its where
  q[1]:$[base and isupd;(tree.selop;ts`tn;tree.setc pf;0b;vcols!vcols);ts`slot];
  if[base and not isupd;w:ord.place[pol.info[c`p;ts`tn];c`cfg;w;pf]];
  q[2]:tree.setc w;
  q[3]:bc 0;
  q[4]:sc 0;
  if[5<count q;q:(5#q),extras[c;depth;s;sc 1;5_q]];
  :(q;sc 1);
  };

rewrite:{[c;q]
  / the safe parse tree, or a signal
  tree.chk[not tree.hasfilehandle q;"file handle symbols are not permitted"];
  :first walk[c;nocols;0;q];
  };

export:([ctx;rewrite]);
