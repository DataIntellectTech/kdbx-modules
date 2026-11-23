/ di.qsp.core.fns - the function whitelist
/ parse trees hold function values, not names, so the whitelist is a name!value dictionary and
/ membership is tested by identity. A policy starts from defaults and is narrowed or widened with
/ policy.allowfunction / policy.denyfunction; nothing on the never list can be added whatever the
/ policy says

tree:use`..tree;

resolve:{[n]
  / a function from its name. A q keyword is not reachable with value on its symbol - value`sum
  / fails where value"(sum)" works - so resolution tries both
  if[tree.isfn v:@[value;n;(::)];:v];
  if[tree.isfn v:@[value;"(",string[n],")";(::)];:v];
  '"qsp: cannot resolve function ",string n;
  };

/ ------------------------------------------------------------------ never-allow
/ anything that evaluates text, reaches the filesystem or a handle, mutates a global, or names a
/ global by symbol. hdel is deliberately absent: it is not (~:), told apart only by argument type,
/ so it is closed off by refusing file handle symbols (tree.q) and by substituting not for notsafe

nevernames:`value`get`set`system`hopen`hclose`hcount`read0`read1`save`load,
  `rsave`rload`dsave`parse`show`exit`getenv`setenv`reval`eval`insert`upsert,
  `key`hsym`ssr`enum`fkeys`view`views;

/ the amend/apply and assign operators, which have no name to resolve
operators:{[] :(first parse".[a;b;c;d]";first parse"@[a;b;c;d]";first parse"a:1";first parse"a::1");};

/ the function value for a name, or (::) if there is none
tryresolve:{[n] :@[resolve;n;(::)];};

neverfns:{x where not (::)~/:x} (tryresolve each nevernames),@[operators;::;{()}];
never:{[v] :any v~/:neverfns;};

/ a name for a function that is not whitelisted, so a refusal can say what was refused - a caller
/ that is a query generator can repair a query that names its problem, and can do nothing with
/ "<not permitted>"
namedfns:{(k where b)!v where b:not (::)~/:v:tryresolve each k:x} nevernames;
name:{[v] :$[(count namedfns)>i:(value namedfns)?v;(key namedfns)i;.q?v];};

/ ------------------------------------------------------------------ substitution
/ primitives overloaded by argument type where one overload is dangerous are swapped for a
/ guarded wrapper as the tree is rewritten. not-on-a-symbol is an error in q anyway, so refusing
/ it costs nothing and closes file deletion

notsafe:{$[11h=abs type x;'"qsp: not cannot be applied to a symbol";not x]};
/ the grade of a select[<c] or select[>c] sort is hopen or hclose when q applies it to an atom:
/ select[<5000] opens a connection, select[>3] closes handle 3. The walker swaps in these, which
/ only sort
ascsafe:{$[0>type x;'"qsp: a sort must be by a column, not an atom";iasc x]};
descsafe:{$[0>type x;'"qsp: a sort must be by a column, not an atom";idesc x]};

subfrom:enlist resolve`not;
subto:enlist notsafe;
subst:{[f] :$[(count subfrom)>i:subfrom?f;subto i;f];};

/ q renders a<>b, a<=b and a>=b as a composition of not with =, > and <. The composing iterator
/ has no name, so it is whitelisted by value
compose:@[{first (parse"a<>b")0};::;{(::)}];

/ ------------------------------------------------------------------ symbols resolved at run time
/ q resolves a symbol atom as the name of a global wherever it applies one or hands one to a
/ function that reads a table by name: (`$"f")[1] calls f, cols`t and `k xasc`t read or rewrite
/ the global t, f each `t and 2?`t read it, `sym?`x extends the database's enumeration (and with a
/ file handle on the left, writes a file). The walker checks every name written in the tree, but a
/ symbol computed while the query runs - `$"t", first `a`t, the output of cols - is not in it
/ so the rule is fail-closed. A pure function is one verified not to resolve a symbol in any
/ argument, nor to apply a function it is given: comparison, arithmetic, aggregation, string and
/ set primitives. Each argument of anything else is checked - a literal as the tree is rewritten, a
/ computed value by one of the checks below, which the walker wraps around it (walk.q). A function
/ added with policy.allowfunction is never pure

purenames:(`$("=";"<>";"<";">";"<=";">=";"~";"&";"|";"+";"-";"*";"%";",";"^")),
  `in`within`like`not`and`or`null`any`all`differ`fills`prev`next`xprev,
  `div`mod`abs`neg`signum`sqrt`log`exp`xexp`xlog`reciprocal`ceiling`floor,
  `sum`avg`min`max`count`first`last`med`dev`sdev`var`svar`wsum`wavg`prd,
  `cor`cov`distinct`sums`maxs`mins`prds`avgs`deltas`ratios`mcount`msum,
  `mavg`mmax`mmin`mdev`ema`asc`desc`iasc`idesc`rank`reverse`enlist`raze,
  `string`xbar`group`where`except`inter`union`lower`upper`trim`ltrim`rtrim,
  `type`bin`binr`ss`sv`vs`flip;
purefns:{x where not (::)~/:x} (tryresolve each purenames),enlist notsafe;

ispure:{[f]
  / will f, applied to anything, never resolve a symbol or apply a function it is given? A
  / projection is its base function; a composition, all of its parts. Anything an iterator derives
  / applies its function, and resolves a symbol atom it is applied to, so is never pure
  / a name on the list is pure whatever its type: sums is +\, raze ,/ and prev a projection of
  / an each-prior, and each was checked as itself (not as what derived it) never to resolve a
  / symbol or apply a function, with one argument or two
  if[(count purefns)>purefns?f;:1b];
  t:type f;
  if[t within 100 103;:0b];
  if[t=104h;:.z.s first value f];
  if[t=105h;:all .z.s each value f];
  :0b;
  };

/ the iterators, as parse leaves them: (';f) is f each, and (';f;g) composes f with g
iters:{x where not (::)~/:x} @[{(first parse x)0};;{(::)}] each ("f'[x]";"f/[x]";"f\\[x]";"f':[x]";"f/:[x]";"f\\:[x]");
isiter:{[f] :any f~/:iters;};

/ the checks, each applied to a value as the query computes it, returning it unchanged or signalling

/ a value that may not be a symbol: an argument q could read as a table or list by name
nosym:{$[-11h=type x;'"qsp: a symbol cannot be used here - q would read it as the name of a global";x]};

/ does x hold a function that is not pure, at any depth? q applies a list, a dictionary or a
/ table to arguments by indexing it at depth, and an item it reaches with arguments left over is
/ applied to them: (each;count)[0;f;y] is each[f;y], and (?;count)[0;`t;();0b;()] reads t
impure:{[x]
  t:type x;
  if[t within 100 112;:not ispure x];
  if[t=98h;:.z.s value flip x];
  if[t=99h;:.z.s[key x]|.z.s value x];
  if[t<>0h;:0b];
  / most lists hold no list or function at all: settle those without looking at each item
  ty:type each x;
  if[not any (ty within 100 112)|ty in 0 98 99h;:0b];
  :any .z.s each x;
  };

/ a value q will apply: data holding no function but the pure ones, which q indexes, or a pure
/ function. Never an atom: q applies an int as a handle - 0"text" evaluates the text, -1"text"
/ writes to stdout, h"text" sends it down an open connection - a symbol as the name of a global,
/ and any other atom is an error in q anyway
fnarg:{
  if[-11h=type x;'"qsp: a symbol cannot be applied - q would call the global it names"];
  if[0>type x;'"qsp: ",(-3!x)," cannot be applied - q applies an int as a handle, and no atom can be indexed"];
  if[not (type x) within 100 112;
    if[impure x;'"qsp: data holding a function cannot be applied - q would apply the function it reaches"];
    :x];
  if[ispure x;:x];
  '"qsp: only q's simple functions can be applied here, not ",$[null n:name x;"a function the query computed";string n];
  };

/ the right side of a comparison the user computed: one value, as q compares a list row by row
/ (see order.q - a list long enough to match would count rows the user cannot see)
scalar:{$[0>type x;x;'"qsp: a comparison in a where clause takes one value - use in for a list"]};
pair:{$[$[0h=type x;(2=count x)&all 0>type each x;(0<type x)&2=count x];x;'"qsp: within takes two values, low and high"]};
pattern:{$[(type x) in -10 10h;x;'"qsp: like takes one pattern, as a string"]};

/ the left of $: a type name casts; any other symbol names an enumeration domain, which q reads.
/ The extractions - `hh$t, `uu$t, `ss$t, `mm$d, `dd$d, `year$d, `week$d - are q's own: a global of
/ the same name does not change them, so they are as safe as a type name
typenames:``boolean`guid`byte`short`int`long`real`float`char`symbol`timestamp`month`date,
  `datetime`timespan`minute`second`time;
extractions:`year`mm`dd`hh`uu`ss`week;
castnames:typenames,extractions;
/ the names q reads after a dot on a temporal column, time.minute or d.year, as that cast
accessors:`date`month`minute`second`time`timespan`timestamp,extractions;
castarg:{$[-11h<>type x;x;x in castnames;x;'"qsp: ",string[x],"$ casts to an enumeration - cast to a type name (`minute, `date, `float...) or extract with `hh, `uu, `ss, `mm, `dd, `year or `week"]};

/ fby's (function;column): the function is applied. q's fby takes the function as x 0, so it
/ applies a symbol pair - `f`c - as readily as (f;`c), and indexes a dictionary as well as a list
fbyarg:{
  if[not (type x) in 0 11h;'"qsp: fby takes (function;column)"];
  if[count x;fnarg first x];
  :x;
  };
/ wj's (table;(function;column);...): a symbol table is read as a global, and each function is
/ applied - from a symbol pair, `f`c, as readily as from (f;`c)
wjagg:{
  if[0h<>type x;'"qsp: wj takes (table;(function;column);...)"];
  nosym first x;
  {if[not (0h=type x)&2<=count x;'"qsp: wj aggregates with (function;column) pairs"]; fnarg first x} each 1_x;
  :x;
  };

/ x?y with a symbol on the left extends the enumeration it names, and from an atom on the left
/ rolls or deals from the list a symbol on the right names. A list on the left finds
findsafe:{[x;y]
  if[-11h=type x;'"qsp: a symbol cannot be used as the left of ? - q would extend the enumeration it names"];
  if[(0>type x)&-11h=type y;'"qsp: a symbol cannot be the right of ? here - q would read it as the name of a global"];
  x?y};

/ ------------------------------------------------------------------ argument rules
/ how the walker checks each argument of a call to f with n arguments
/   `none   nothing - the function never resolves a symbol there
/   `data   may not be a symbol atom
/   `fn     is applied: data, or a pure function
/   `cast   the left of $: a type name
/   `fby    fby's (function;column)
/   `wjagg  wj's aggregation list

higher:{x where not (::)~/:x} tryresolve each `each`peach`prior`over`scan;
/ a column list in the first argument: `sym xasc t, aj[`sym`time;t;q]. The table after it is read
/ by name if it is a symbol - `sym xasc `trade sorts the global - so it may not be one
colfirst:{x where not (::)~/:x} tryresolve each `xasc`xdesc`xcols`xcol`aj`aj0`ej;
/ # and _ never read a symbol as a global's name, on either side: 3#`t is `t`t`t, and `a#`t and
/ `a _ `t are type errors. So neither argument is checked: `a`b#t, 30#`MSFT and d _ `k all run.
/ (`$("#";"_") would be one symbol, `#_: two one-character strings are one two-character string)
takedrop:{x where not (::)~/:x} tryresolve each `$(1#"#";1#"_");
wjs:{x where not (::)~/:x} tryresolve each `wj`wj1;
castop:resolve`$"$";
findop:resolve`$"?";
fbyop:resolve`fby;

pad:{[c;n] :n#c,n#`data;};

rules:{[f;n]
  if[ispure f;:n#`none];
  if[isiter f;:n#`fn];
  if[any f~/:higher;:pad[`fn;n]];
  if[f~fbyop;:pad[`fby;n]];
  if[any f~/:wjs;:pad[`none`data`data`wjagg;n]];
  if[any f~/:colfirst;:pad[`none;n]];
  if[any f~/:takedrop;:n#`none];
  / $[c;a;b] and ?[c;a;b] are conditionals: they return a symbol, but never resolve one
  if[(f~castop)&2<n;:n#`none];
  if[f~castop;:n#`cast`none];
  if[(f~findop)&2<n;:n#`none];
  :n#`data;
  };

catalog:{[ns]
  / name!value for a list of names, refusing anything on the never list
  ns:(),ns;
  v:resolve each ns;
  if[any b:never each v;
    '"qsp: refusing to whitelist ",(", " sv string ns where b)," - on the never-allow list"];
  :ns!v;
  };

/ ------------------------------------------------------------------ defaults
/ enough to write real analytics; nothing that can evaluate text, reach the filesystem, open a
/ handle or assign a global

defaults:catalog (`$("=";"<>";"<";">";"<=";">=";"~";"&";"|";"+";"-";"*";"%";
  "#";"_";",";"!";"?";"$";"^")),
  `in`within`like`not`and`or`null`any`all`differ`fills`prev`next`xprev,
  `div`mod`abs`neg`signum`sqrt`log`exp`xexp`xlog`reciprocal`ceiling`floor,
  `sum`avg`min`max`count`first`last`med`dev`sdev`var`svar`wsum`wavg`prd,
  `cor`cov`distinct`sums`maxs`mins`prds`avgs`deltas`ratios`mcount`msum,
  `mavg`mmax`mmin`mdev`ema`each`over`scan`peach`prior,
  `asc`desc`iasc`idesc`rank`reverse`xasc`xdesc`sublist`til`enlist`raze,
  `flip`string`cols`xbar`xcol`xcols`group`ungroup`fby`where`except`inter,
  `union`lower`upper`trim`ltrim`rtrim`type`bin`binr`ss`sv`vs,
  `lj`ij`uj`pj`ej`aj`aj0`wj`wj1`cross`meta;
if[not (::)~compose;defaults[`compose]:compose];

export:([resolve;never;name;notsafe;ascsafe;descsafe;subst;compose;catalog;defaults;
  ispure;isiter;rules;impure;nosym;fnarg;castarg;castnames;accessors;castop;fbyarg;wjagg;findop;findsafe;scalar;pair;pattern]);
