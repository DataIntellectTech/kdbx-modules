/ di.qsp.admin - the admin UI: a web page for writing, testing and exploring a policy
/   qsp.adminui`local                  serve it to this machine, on the process's port or 8080
/   qsp.adminui`public                 ...to any machine that can reach the port
/   qsp.adminui ([access:`local;port:8080;dir:"/path/to/policy"])
/   qsp.adminui`stop                   put the handlers back, and close the port if it opened one
/ call it in a process with the data loaded - an HDB, an RDB, a fresh database - and open the
/ address it prints. With no policy yet, the page sets one up: point it at a policy directory, or
/ create one from the tables loaded here (scaffold). Then it maps who reaches what, lays each
/ user's view over the real rows, runs q as any user, runs the policy's tests, and edits the
/ files - checking an edit, showing what it changes for whom and which tests it breaks, before
/ saving it
/ an admin tool, not a policed process. Anyone who reaches the page can query as any user, see
/ the rows a policy hides, and write the policy's files. So it answers this machine only unless
/ `public, never runs in a process serving a policy, and writes only when the page asks to save.
/ The page itself is ui/, plain HTML and JavaScript, read from disk on every request

tree:use`..core.tree;
fns:use`..core.fns;
pol:use`..policy;
files:use`..policy.files;
rev:use`..policy.review;
api:use`..api;
suite:use`..policy.suite;

/ ui/, beside this file. A module function knows the file it was defined in (value gives it, third
/ from last); .z.f while a module loads is the script that loaded it, not the module
mark:{[] };
uidir:{[f] :((1+last where f="/")#f),"ui/";} first -3#value mark;

/ ------------------------------------------------------------------ state
/ Q: the functions init.q lends (run, runx, ... - see adminui there)
/ dir: the policy directory, "" for none. P: its policy, (::) while it does not load, with PR the
/ problems. P0: as the files have it - a what-if may swap in an edited P for the session. T, TP:
/ its tests, and the problems with tests.csv

Q:()!();
dir:"";
P:(::);
P0:(::);
PR:([]file:`symbol$();line:`long$();error:());
edited:0b;
ED:()!();
T:();
TP:([]file:`symbol$();line:`long$();error:());
access:`local;
opened:0b;
before:`.z.ph`.z.pp!(::;::);
running:0b;

hasdir:{[] :0<count dir;};
ok:{[] :not (::)~P;};
chkok:{[] tree.chk[ok[];"no policy is loaded - open or create one in Setup"];};

/ the policy in directory d, as far as it loads: sets P, PR, T, TP
open:{[d]
  .z.m.dir:$[0=count d;"";"/"=first d;d;system["cd"],"/",d];
  .z.m.edited:0b;
  .z.m.ED:()!();
  .z.m.P:.z.m.P0:(::);
  .z.m.T:();
  .z.m.PR:.z.m.TP:0#PR;
  if[not hasdir[];:()];
  .z.m.PR:files.check dir;
  if[0=count PR;
    r:@[{(1b;files.fromfiles x)};dir;{(0b;x)}];
    $[r 0;.z.m.P:.z.m.P0:r 1;.z.m.PR:([]file:enlist`;line:enlist 0;error:enlist r 1)]];
  .z.m.TP:suite.problems dir;
  if[0=count TP;.z.m.T:@[suite.fromdir;dir;{()}]];
  };

/ ------------------------------------------------------------------ JSON

/ a number type's infinities, which JSON cannot hold
infs:(5 6 7 8 9h)!(0Wh;0Wi;0W;0we;0w);

js:{[x]
  / x, as .j.j can write it: enumerations as their symbols, a keyed table unkeyed, an infinity or
  / a null symbol as null, a function as its text
  t:type x;
  if[t within 20 76;:value x];
  if[t within -76 -20;:value x];
  if[t within 100 112;:-3!x];
  if[t=0h;:.z.s each x];
  if[t=98h;:flip .z.s each flip x];
  if[t=99h;:$[98h=type key x;.z.s 0!x;(key x)!.z.s each value x]];
  if[t=-11h;:$[null x;(::);x]];
  if[(abs t) in key infs;
    b:(abs x)=infs abs t;
    :$[t<0;$[b;(::);x];$[any b;{$[y;(::);x]}'[x;b];x]]];
  :x;
  };
json:{[x] :.j.j js x;};

/ ------------------------------------------------------------------ results as a grid

/ q's name for each type character
typenames:" bgxhijefcspmdznuvt"!``boolean`guid`byte`short`int`long`real`float`char`symbol`timestamp`month`date`datetime`timespan`minute`second`time;
tyname:{[c] :$[c in key typenames;typenames c;(lower c) in key typenames;`$string[typenames lower c],"[]";`$enlist c];};

/ a column as cells: numbers, booleans, symbols and strings as they are, everything else as q
/ writes it, so a time reads 09:30:00.000 rather than whatever JSON would make of it
cells:{[v]
  if[(type v) within 20 76;v:value v];
  / a nested column of a splayed table comes back mapped from disk (77h to 97h): string would
  / treat each string as a list of chars, so index it into an ordinary list first
  if[(type v) within 77 97;v:v til count v];
  t:type v;
  if[t in 1 5 6 7 8 9 11h;:v];
  if[t=0h;:{$[10h=type x;x;-11h=type x;string x;0>type x;$[(type x) in -1 -5 -6 -7 -8 -9h;x;string x];-3!x]} each v];
  :string v;
  };

/ any result as (columns; their types; rows, at most n; how many rows; q's own rendering)
grid:{[v;n]
  k:$[98h=type v;`table;99h=type v;$[98h=type key v;`keyed;`dict];0h=type v;`list;0>type v;`atom;`vector];
  t:$[k in `table`keyed;0!v;
    k=`dict;$[98h=type value v;(flip (enlist`key)!enlist key v),'value v;flip `key`value!(key v;value v)];
    k=`atom;flip (enlist`value)!enlist enlist v;
    flip (enlist`value)!enlist v];
  c:cols t;
  ty:{[t;c] tyname .Q.ty t c}[t] each c;
  r:n sublist t;
  rows:flip cells each r c;
  txt:@[{-1_.Q.s x};n sublist v;{"<unrenderable>"}];
  :`kind`columns`types`rows`count`text!(k;c;ty;$[count r;rows;()];count v;4000 sublist txt);
  };

/ ------------------------------------------------------------------ q text for a rewritten tree
/ qsp.explain shows the parse tree that runs. This writes it back as q-SQL, with qsp's run-time
/ checks shown as the expressions they check: the page marks what the policy added

guards:(fns.nosym;fns.fnarg;fns.castarg;fns.fbyarg;fns.wjagg;fns.scalar;fns.pair;fns.pattern);
composeop:first first parse"a<>b";
negated:(=;>;<)!("<>";"<=";">=");
infixw:`in`within`like`and`or`mod`div`xbar`except`inter`union`bin`binr`xexp`xlog`wavg`wsum,
  `each`over`scan`prior`peach`xasc`xdesc`xcol`xcols`xkey`sv`vs`ss`cross`lj`ij`uj`pj`ej`fby`cor`cov`set;

fnname:{[x]
  if[x~fns.notsafe;:"not"];
  if[ok[];
    ks:key P`fns;
    if[(count ks)>i:(value P`fns)?x;:string ks i]];
  :$[null n:fns.name x;-3!x;string n];
  };
issym:{[n] :all n in "=<>~&|+-*%#_,!?$^@.";};
isinfix:{[n] :((`$n) in infixw)or issym n;};

/ data as q text, never k's one-item ,x
qlit:{[x]
  if[0h=type x;:$[1=count x;"enlist ",.z.s first x;"(",(";"sv .z.s each x),")"]];
  if[(0<type x)and 1=count x;:"enlist ",-3!first x];
  :-3!x;
  };

qt:{[x]
  t:type x;
  if[t=-11h;:string x];
  if[t=11h;:$[1=count x;qlit first x;string[first x],"[",(";"sv qt each 1_x),"]"]];
  if[tree.isfn x;:fnname x];
  if[t<>0h;:qlit x];
  if[0=count x;:"()"];
  if[1=count x;:qlit first x];
  if[tree.isquery x;:qquery x];
  h:first x;
  a:1_x;
  if[(2=count x)and any h~/:guards;:qt a 0];
  if[h~fns.findsafe;h:fns.findop];
  if[h~enlist;:$[1=count a;"enlist ",argt a 0;"(",(";"sv qt each a),")"]];
  / a<>b, a<=b and a>=b are a composition of not with =, > and <
  if[(0h=type h)and 3=count h;
    if[(composeop~h 0)and any (h 1)~/:(not;fns.notsafe);
      if[(count key negated)>i:(key negated)?h 2;:argt[a 0],(value negated)[i],argt a 1]]];
  if[0h=type h;:"(",qt[h],")[",(";"sv qt each a),"]"];
  if[-11h=type h;:string[h],"[",(";"sv qt each a),"]"];
  n:fnname h;
  if[(2=count a)and isinfix n;:argt[a 0],$[issym n;n;" ",n," "],argt a 1];
  if[1=count a;:n," ",argt a 0];
  :n,"[",(";"sv qt each a),"]";
  };
/ is application x written with an operator, infix or prefix, rather than as f[args]? Its text
/ then needs brackets to be an argument
isop:{[x]
  if[not (0h=type x)and 1<count x;:0b];
  if[tree.isquery x;:1b];
  h:first x;
  if[(2=count x)and any h~/:guards;:.z.s x 1];
  if[h~enlist;:2=count x];
  if[0h=type h;:3=count h];
  if[not tree.isfn h;:0b];
  if[h~fns.findsafe;:1b];
  :(2=count x)or(3=count x)and isinfix fnname h;
  };
argt:{[x] s:qt x; :$[isop x;"(",s,")";s];};

/ a select or exec's columns: name:expression, or just the name where they are the same
qcols:{[a]
  if[a~();:""];
  if[99h<>type a;:", "sv qt each a];
  :", "sv {[k;v] $[v~k;string k;string[k],":",qt v]}'[key a;value a];
  };

qquery:{[x]
  upd:x[0]~tree.updop;
  t:x 1; w:tree.getc x 2; b:x 3; a:x 4;
  src:$[-11h=type t;string t;"(",qt[t],")"];
  wh:$[count w;" where ",", "sv qt each w;""];
  bys:$[99h=type b;" by ",qcols b;(0h=type b)and 0<count b;" by ",", "sv qt each b;11h=type b;" by ",", "sv string b;""];
  if[upd;
    if[11h=type a;:"delete from ",src,wh];
    if[(0h=type a)and 11h=type first a;:"delete ",(", "sv string first a)," from ",src,wh];
    :"update ",qcols[a],bys," from ",src,wh];
  ex:(b~())or(0h=type b)and 0<count b;
  if[11h=type b;ex:1b];
  ext:"";
  if[5<count x;
    ext:"[",qt[x 5],$[6<count x;";",$[(first first x 6)~fns.descsafe;">";"<"],qt last first x 6;""],"]"];
  :$[ex;"exec";"select",$[b~1b;" distinct";""]],ext,$[count c:qcols a;" ",c;""],bys," from ",src,wh;
  };
qshow:{[x] :@[qt;x;{[x;e] -3!x}x];};

/ ------------------------------------------------------------------ the policy files
/ each file, and for each row of each, the line it is on and its first cells - what the page
/ highlights when something is selected

csvfiles:`tables`schema`grants`members`gateways`functions`config`tests;
fpath:{[f] :hsym`$dir,"/",f;};
disklines:{[f] :$[hasdir[];@[read0;fpath f;{()}];()];};
lines:{[f] :$[(`$f) in key ED;ED`$f;disklines f];};
splitlines:{[t] l:"\n" vs t; :$[(0<count l)and 0=count last l;-1_l;l];};

/ the data rows of a csv: (line number; first n cells)
csvrows:{[f;n]
  l:lines f;
  i:where not {(0=count x)or"#"=first x} each trim each l;
  i:1_i;
  :([]line:1+i;k:{[n;s] `$trim n#("," vs s),n#enlist""}[n] each l i);
  };

/ the names defs.q defines, and the line each starts on
defsrows:{[]
  l:lines "defs.q";
  i:where {(0<count x)and(x[0]in .Q.a,.Q.A)and 0<count ss[x;":"]} each l;
  n:{`$first ":" vs x} each l i;
  b:{all (string x) in .Q.an} each n;
  :([]name:n where b;line:1+i where b);
  };

sources:{[]
  :`tables`schema`grants`members`gateways`config`defs`tests!(csvrows["tables.csv";1];csvrows["schema.csv";2];
    csvrows["grants.csv";2];csvrows["members.csv";2];csvrows["gateways.csv";1];csvrows["config.csv";1];defsrows[];
    csvrows["tests.csv";1]);
  };

filelist:{[]
  fs:(string[csvfiles],\:".csv"),enlist "defs.q";
  fs:fs where 0<count each lines each fs;
  :{`name`lines!(x;lines x)} each fs;
  };

diskfilelist:{[]
  fs:(string[csvfiles],\:".csv"),enlist "defs.q";
  fs:fs where 0<count each disklines each fs;
  :{`name`lines!(x;disklines x)} each fs;
  };

/ ------------------------------------------------------------------ the database here

/ the tables this process has loaded: name, partition column (` if none), columns, rows
dbtables:{[]
  ts:asc tables`.;
  pt:{$[1b~@[.Q.qp;get x;0b];.Q.pf;`]} each ts;
  n:{[t;p] $[null p;@[count;get t;0N];0N]}'[ts;pt];
  :flip `tbl`partition`columns`rows!(ts;pt;{cols x} each ts;n);
  };

/ ------------------------------------------------------------------ the overview

/ a grant's row filter as a where clause, and what kind it is
fnof:{[f] :$[count n:{[f;x] x where f~/:@[get;;::] each x}[f] system"f";"fn:",string first n;"a function"];};
rowsof:{[r]
  if[100h=type r;:(fnof r;`fn)];
  if[0=count r;:("all rows";`none)];
  s:@[rev.clause[P;`];r;{"<",x,">"}];
  :(s;$[s like "*qsp.aged*";`aged;s like "*qsp.USER*";`user;s like "*[[]*";`lookup;`static]);
  };

/ tests as the page shows them: the q value of an equals test is left in its text
testrows:{[t] :$[count t;select line,user,query,expect,value,note from t;()];};

/ what the page needs when there is no policy to show: where it is, what is wrong, the files
basics:{[]
  :`state`dir`problems`files`diskfiles`sources`db`dates`edited`tests`testproblems`drift`version!(
    $[not hasdir[];`none;ok[];`ok;`broken];dir;PR;filelist[];diskfilelist[];$[hasdir[];sources[];()!()];dbtables[];
    string @[value;`.Q.pv;()];edited;testrows T;TP;$[hasdir[];@[files.schemadrift;dir;{()}];()];Q`version);
  };

overview:{[]
  b:basics[];
  if[not ok[];:b];
  s:b`sources;
  g:P`grants;
  ro:rowsof each g`rows;
  allc:{[t] exec col from P[`schema] where tbl=t};
  gl:{[s;e;t] first exec line from s[`grants] where k~\:(e;t)}[s]'[g`entity;g`tbl];
  gr:([]entity:g`entity;tbl:g`tbl;
    columns:{[a;t;c] $[pol.allcols in c;a t;(),c]}[allc]'[g`tbl;g`columns];
    allcols:pol.allcols in/: g`columns;rows:ro[;0];kind:ro[;1];line:gl);
  m:P`members;
  ml:{[s;u;e] first exec line from s[`members] where k~\:(u;e)}[s]'[m`user;m`entity];
  tl:{[s;t] first exec line from s[`tables] where k~\:enlist t}[s] each key P`tabs;
  tabs:([]tbl:key P`tabs;partition:value P`tabs;
    columns:allc each key P`tabs;
    types:{[t] tyname each exec typ from P[`schema] where tbl=t} each key P`tabs;
    line:tl);
  cl:{[s;n] first exec line from s[`config] where k~\:enlist n}[s] each key P`config;
  cfg:flip `setting`value`line!(key P`config;{$[100h=type x;fnof x;-3!x]} each value P`config;cl);
  :b,`users`gateways`members`grants`tables`access`config`functions`calls`rules`clock`limits!(
    rev.users P;P`gateways;([]user:m`user;entity:m`entity;line:ml);gr;tabs;rev.access[P;`];cfg;
    asc key P`fns;asc P`calls;api.rules[P;`q];string P[`config;`clock][];api.limits[P;`q]);
  };

/ ------------------------------------------------------------------ queries

/ a name from the page (a string) or from another call (a symbol)
asym:{[x] :$[-11h=type x;x;`$x];};

/ the row filters the policy put into a rewritten tree, as text, for the page to mark
injected:{[u;rw]
  ts:tree.basetables rw;
  :distinct raze {[u;t] qt each @[pol.filterfor[P;u];t;{()}]}[u] each ts;
  };

/ a result short enough to write as an equals test's value: an atom, or a short simple list, as q
/ text that parses back to it
litof:{[v]
  v:suite.plain v;
  if[0>type v;:-3!v];
  if[not (type v) within 1 19;:""];
  if[20<count v;:""];
  if[1=count v;:"enlist ",-3!first v];
  :-3!`#v;
  };

runraw:{[u;q]
  chkok[];
  t0:.z.p;
  r:@[{(1b;Q[`runx][P;x;y])}[u];q;{(0b;x)}];
  ms:(`long$.z.p-t0)%1e6;
  rw:@[{(1b;Q[`rewrite][P;x;y])}[u];q;{(0b;x)}];
  res:`ok`ms`user`query`rewritten`tree`injected!(r 0;ms;u;q;$[rw 0;qshow rw 1;""];$[rw 0;.Q.s1 rw 1;""];
    $[rw 0;injected[u;rw 1];()]);
  :(r 0;$[r 0;r[1;0];r 1];$[r 0;res,`result`lit!(grid[r[1;0];500];litof r[1;0]);res,enlist[`error]!enlist r 1]);
  };

run:{[a] :last runraw[asym a`user;a`query];};

/ the same query as every user: what each got
compare:{[a]
  chkok[];
  q:a`query;
  :{[q;u] r:run`user`query!(u;q);
    `user`ok`count`error`ms!(u;r`ok;$[r`ok;r[`result;`count];0N];$[r`ok;"";r`error];r`ms)}[q] each rev.users P;
  };

/ a sample of table t's rows, as they are, and which of them and which of their columns user u
/ sees: the mask is the user's own row filter and columns, applied to the sample
lens:{[a]
  chkok[];
  u:asym a`user;
  t:asym a`table;
  tree.chk[pol.known[P;t];"not a table of this policy: ",string t];
  tree.chk[@[{.Q.qt get x};t;0b];string[t]," is not loaded in this process"];
  n:$[`n in key a;`long$a`n;60];
  pc:P[`tabs;t];
  ds:@[value;`.Q.pv;()];
  d:$[null pc;0N;`date$$[`date in key a;"D"$a`date;last ds]];
  raw:$[null pc;0!value t;?[t;enlist(=;pc;d);0b;()]];
  tot:count raw;
  / spread the sample over the table: its rows are often grouped by sym, and a filter on one would
  / otherwise see one block
  s:$[tot>n;raw floor (til n)*tot%n;raw];
  s:update qspi:i from s;
  vc:pol.columnsfor[P;u;t];
  f:@[{(1b;pol.filterfor[P;x;y])}[u];t;{(0b;x)}];
  vr:$[0=count vc;`long$();not f 0;`long$();exec qspi from ?[s;f 1;0b;()]];
  / what the user's own query of the whole partition returns
  q:"select from ",string[t],$[null pc;"";" where ",string[pc],"=",string d];
  rr:run`user`query!(u;q);
  :`table`user`date`columns`types`visiblecolumns`visiblerows`sample`total`filter`via`query`seen`error!(
    t;u;$[null d;"";string d];cols raw;{[t;c] tyname .Q.ty t c}[raw] each cols raw;vc;vr;
    (grid[delete qspi from s;n])`rows;tot;
    @[{rev.clause[P;x] pol.rawfilter[P;x;y]}[u];t;{"refused: ",x}];
    exec distinct raze via from rev.access[P;u] where tbl=t;q;$[rr`ok;rr[`result;`count];0N];$[rr`ok;"";rr`error]);
  };

/ one of the policy's tests: qsp.runtests' verdict, and the run itself to show
test:{[a]
  chkok[];
  t:T `long$a`i;
  rr:runraw[t`user;t`query];
  v:suite.verdict[t;(rr 0;rr 1)];
  :(rr 2),`pass`got`line!(v 0;v 1;t`line);
  };

audit:{[a]
  n:$[`n in key a;`long$a`n;100];
  :reverse neg[n] sublist select time,user,query,decision,reason from Q[`audit][];
  };

describe:{[a] chkok[]; :api.describe[P;asym a`user;`q];};
validate:{[a] chkok[]; :Q[`apis][`validate][P;asym a`user;a`query;`q];};

/ ------------------------------------------------------------------ setting up and editing

/ a csv cell, quoted as a spreadsheet would if it holds a comma or a quote
csvcell:{[x] :$[any x in ",\"";"\"",ssr[x;"\"";"\"\""],"\"";x];};

/ a scratch directory, for checking files before anything is written
scratch:$[count t:getenv`TMPDIR;t;"/tmp"],"/qsp-admin-",string .z.i;
fresh:{[d] system"rm -rf ",d; system"mkdir -p ",d; :d;};

/ the policy's files with some replaced, copied to directory d: a file not there stays not there
copyto:{[d;ed]
  {[d;ed;f] fp:hsym`$d,"/",f;
    $[(`$f) in key ed;fp 0: splitlines ed`$f;count l:lines f;fp 0: l;::]}[d;ed] each string[csvfiles],\:".csv";
  :d;
  };

/ open the policy in a directory
openpolicy:{[a] open a`dir; :basics[];};

/ create a policy in a directory, from tables loaded here: every table, column and partition, and
/ a grant row per table naming no one - so it grants nothing until someone says who it is for
create:{[a]
  d:a`dir;
  tree.chk[0<count d;"name the directory to create the policy in"];
  ts:$[`tables in key a;`$a`tables;`];
  if[(11h=type ts)and 0=count ts;ts:`];
  files.scaffold[d;ts];
  open d;
  :basics[];
  };

/ an edit: the policy's files with some replaced, checked and loaded from a scratch copy - the
/ real files are not written. Returns the problems, or what would change for whom and which tests
/ break. apply swaps it in for this session
preview:{[a]
  ed:$[99h=type a`files;a`files;()!()];
  d:copyto[fresh scratch;ed];
  pr:files.check[d],suite.problems d;
  if[count pr;:`ok`problems!(0b;pr)];
  p2:@[files.fromfiles;d;{x}];
  if[10h=type p2;:`ok`problems!(0b;([]file:enlist`;line:enlist 0;error:enlist p2))];
  diff:rev.diff[$[ok[];P;pol.new[]];p2];
  t2:suite.fromdir d;
  tr:$[count t2;select line,user,query,expect,value,note,pass,got from Q[`runtests][p2;t2];()];
  if[a[`apply]~1b;
    .z.m.P:p2;.z.m.edited:1b;.z.m.T:t2;.z.m.PR:0#PR;.z.m.TP:0#TP;
    if[count ed;.z.m.ED:ED,(key ed)!splitlines each value ed]];
  :`ok`diff`tests`applied!(1b;diff;tr;a[`apply]~1b);
  };

/ write edited files to the policy directory, then load it again. Problems do not stop a save -
/ a policy is often written over several - but the page says what they are first
savefiles:{[a]
  tree.chk[hasdir[];"no policy directory - open or create one in Setup"];
  ed:$[99h=type a`files;a`files;()!()];
  tree.chk[0<count ed;"nothing to save"];
  bad:(key ed) except `$string[csvfiles],\:".csv";
  tree.chk[0=count bad;"not a policy file: ",", "sv string bad];
  {[f;t] (fpath string f) 0: splitlines t}'[key ed;value ed];
  open dir;
  :basics[];
  };

/ update schema.csv from the tables loaded in this process
syncschema:{[a]
  tree.chk[hasdir[];"no policy directory - open or create one in Setup"];
  ts:distinct $[ok[];key P`tabs;raze (csvrows["tables.csv";1])`k];
  loaded:ts where {1b~@[{.Q.qt get x};x;0b]} each ts;
  m:{0!meta x} each loaded;
  new:raze {[t;m] ([]tbl:(count m)#t;col:m`c;typ:enlist each m`t;att:m`a)}'[loaded;m];
  ls:csv 0: new;
  if[a[`save]~1b;(fpath "schema.csv") 0: ls;open dir];
  :`ok`lines`drift!(1b;ls;$[hasdir[];@[files.schemadrift;dir;{()}];()]);
  };

/ tests from the page, appended to tests.csv - checked on a copy first, so a bad one writes nothing
savetests:{[a]
  tree.chk[hasdir[];"no policy directory - open or create one in Setup"];
  ls:{"," sv csvcell each (x`user;x`query;x`expect;x`value;x`note)} each a`tests;
  if[0=count ls;:`ok`problems!(1b;())];
  was:lines "tests.csv";
  new:$[count was;was;enlist "user,query,expect,value,note"],ls;
  d:fresh scratch,"-tests";
  (hsym`$d,"/tests.csv") 0: new;
  if[count pr:suite.problems d;:`ok`problems!(0b;pr)];
  (fpath "tests.csv") 0: new;
  .z.m.TP:suite.problems dir;
  .z.m.T:@[suite.fromdir;dir;{()}];
  :`ok`written`lines!(1b;count ls;ls);
  };

/ back to the policy as the files have it
reset:{[a] open dir; :1b;};

calls:`overview`run`compare`lens`preview`whatif`reset`audit`describe`validate`test`savetests`open`create`save`syncschema!(
  {[a] overview[]};run;compare;lens;preview;preview;reset;audit;describe;validate;test;savetests;openpolicy;create;savefiles;syncschema);

/ ------------------------------------------------------------------ HTTP

mime:`html`css`js`json`svg`txt!("text/html; charset=utf-8";"text/css; charset=utf-8";
  "text/javascript; charset=utf-8";"application/json";"image/svg+xml";"text/plain; charset=utf-8");
http:{[code;ty;body]
  :"HTTP/1.1 ",code,"\r\nContent-Type: ",mime[ty],"\r\nCache-Control: no-store\r\nConnection: close\r\n",
    "Content-Length: ",string[count body],"\r\n\r\n",body;
  };
/ 127.0.0.1, as an int
loopback:2130706433i;
/ this machine: a connection from 127.0.0.1, or the process itself calling the handlers
allowed:{[] :(access=`public)or(0=.z.w)or .z.a=loopback;};
refused:{[] :http["403 Forbidden";`txt;"the qsp admin UI answers this machine only - start it with qsp.adminui`public"];};

/ a file under ui/: read on every request, so an edit shows on reload
static:{[path]
  f:$[path in ("";"/");"index.html";path];
  if[(f like "*..*")or not f like "[a-z]*";:http["404 Not Found";`txt;"not found"]];
  ext:`$last "." vs f;
  if[not ext in key mime;:http["404 Not Found";`txt;"not found"]];
  r:@[{(1b;"c"$read1 x)};hsym`$uidir,f;{(0b;x)}];
  :$[r 0;http["200 OK";ext;r 1];http["404 Not Found";`txt;"not found"]];
  };

ph:{[x]
  if[not allowed[];:refused[]];
  :static first "?" vs first x;
  };

answer:{[body]
  req:.j.k body;
  c:`$req`call;
  if[not c in key calls;'"unknown call: ",string c];
  a:$[`args in key req;req`args;()!()];
  if[not 99h=type a;a:()!()];
  :calls[c] a;
  };

pp:{[x]
  if[not allowed[];:refused[]];
  s:first x;
  i:s?" ";
  if[not "api"~i#s;:http["404 Not Found";`txt;"not found"]];
  r:@[{(1b;answer x)};(i+1)_s;{(0b;x)}];
  out:@[{json $[x 0;`ok`data!(1b;x 1);`ok`error!(0b;tree.clean x 1)]};r;{json `ok`error!(0b;"cannot encode the result: ",x)}];
  :http["200 OK";`json;out];
  };

/ ------------------------------------------------------------------ starting and stopping

/ the port to listen on: this process's, else the one asked for or 8080, or the next free
listen:{[want]
  if[0<system"p";:system"p"];
  if[want~0;:0];
  p:$[null want;8080;want];
  i:0;
  while[(i<20)and not @[{system"p ",string x;1b};p+i;0b];i+:1];
  tree.chk[i<20;"cannot open a port from ",string[p]," to ",string[p+19]," - name one with port"];
  .z.m.opened:1b;
  :p+i;
  };

stop:{[]
  / put the handlers back as they were, and close the port if adminui opened it
  if[not running;:"the admin UI is not running"];
  {[h;f] $[(::)~f;system"x ",string h;h set f];}'[key before;value before];
  if[opened;system"p 0";.z.m.opened:0b];
  .z.m.running:0b;
  :"the admin UI has stopped";
  };

start:{[q;x]
  / x: `local, `public, `stop, or a dictionary of access, port and dir
  .z.m.Q:q;
  if[x~`stop;:stop[]];
  o:$[99h=type x;x;-11h=type x;(enlist`access)!enlist x;x~(::);()!();'"qsp: adminui takes `local, `public, `stop or a dictionary"];
  bad:(key o) except `access`port`dir;
  tree.chk[0=count bad;"adminui does not know ",", "sv string bad];
  a:$[`access in key o;o`access;`local];
  tree.chk[a in `local`public;"access must be `local or `public"];
  tree.chk[not q[`serving][];"this process serves a policy (qsp.serve) - run the admin UI in a process of its own: it can query as any user"];
  .z.m.access:a;
  if[`dir in key o;open o`dir];
  if[not running;
    .z.m.before:`.z.ph`.z.pp!{@[value;x;{(::)}]} each `.z.ph`.z.pp;
    .z.ph:ph;
    .z.pp:pp;
    .z.m.running:1b];
  port:listen $[`port in key o;`long$o`port;0N];
  url:"http://localhost:",string[port],"/";
  if[port>0;
    ip:@[{first " " vs first system"hostname -I"};::;{string .z.h}];
    -1"";
    -1"  qsp admin UI   ",url;
    $[a=`public;-1"                 http://",ip,":",string[port],"/   (any machine that reaches it can query as any user)";
      -1"                 this machine only - qsp.adminui`public to open it to others"];
    -1"  policy         ",$[hasdir[];dir,$[ok[];"";" - does not load yet: ",string[count PR]," problem(s)"];"none yet - set one up in the page"];
    -1""];
  :url;
  };

export:([start;stop;uidir;open]);
