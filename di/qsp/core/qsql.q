/ di.qsp.core.qsql - a rewritten parse tree as q-SQL text
/ qsp evaluates parse trees, and -3! of one - (?;`trades;,,(=;`date;2026.10.02);0b;...) - is
/ lossless but hard to read: an agent never checked what ran, and a person reading the audit log
/ has the same trouble. This writes a tree back as q-SQL, with qsp's run-time checks shown as the
/ expressions they check: the query as written, with what the policy added.
/ text[nm;x] is that text only when parsing it gives back the same tree - checks aside, and a
/ one-item vector written as enlist - so it can never misstate what ran; otherwise -3!, as
/ before. nm maps function values to the names a policy's whitelist gives them (or is ()!())

tree:use`..tree;
fns:use`..fns;

guards:(fns.nosym;fns.fnarg;fns.castarg;fns.fbyarg;fns.wjagg;fns.scalar;fns.pair;fns.pattern);
composeop:first first parse"a<>b";
joinop:first parse"a,b";
negated:(=;>;<)!("<>";"<=";">=");
infixw:`in`within`like`and`or`mod`div`xbar`except`inter`union`bin`binr`xexp`xlog`wavg`wsum,
  `each`over`scan`prior`peach`xasc`xdesc`xcol`xcols`xkey`sv`vs`ss`cross`lj`ij`uj`pj`ej`fby`cor`cov`set;
/ the sort primitives as select[n;<c] and select[n;>c] hold them
sortprim:{[c] :first first (parse"select[1;",c,"a] from t")6;};
ascop:sortprim"<";
descop:sortprim">";

fnname:{[nm;x]
  if[x~fns.notsafe;:"not"];
  if[x~fns.ascsafe;:"iasc"];
  if[x~fns.descsafe;:"idesc"];
  if[(count nm)>i:(value nm)?x;:string (key nm)i];
  / a binary primitive by its glyph: .q names some of them too - lsq is !
  if[102h=type x;:-3!x];
  :$[null n:fns.name x;-3!x;string n];
  };
issym:{[n] :all n in "=<>~&|+-*%#_,!?$^@.";};
isinfix:{[n] :((`$n) in infixw)or issym n;};

/ data as q text: never k's one-item ,x, and a vector whole - -3! cuts a long one short with ..
qlit:{[x]
  if[0h=type x;:$[1=count x;"enlist ",.z.s first x;"(",(";"sv .z.s each x),")"]];
  if[(0<type x)and 1=count x;:"enlist ",-3!first x];
  if[(type x) in 0 10h;:-3!x];
  if[0>type x;:-3!x];
  if[0=count x;:-3!x];
  if[1h=type x;:(raze string x),"b"];
  if[11h=type x;:raze "`",'string x];
  if[4h=type x;:"0x",raze string x];
  :" "sv -3!'x;
  };

qt:{[nm;x]
  t:type x;
  if[t=-11h;:string x];
  if[t=11h;:$[1=count x;qlit first x;string[first x],"[",(";"sv qt[nm] each 1_x),"]"]];
  if[tree.isfn x;:fnname[nm;x]];
  if[t<>0h;:qlit x];
  if[0=count x;:"()"];
  if[1=count x;:qlit first x];
  if[tree.isquery x;:qquery[nm;x]];
  h:first x;
  a:1_x;
  if[(2=count x)and any h~/:guards;:qt[nm;a 0]];
  if[h~fns.findsafe;h:fns.findop];
  if[h~enlist;:$[1=count a;"enlist ",argt[nm;a 0];"(",(";"sv qt[nm] each a),")"]];
  / a<>b, a<=b and a>=b are a composition of not with =, > and <
  if[(0h=type h)and 3=count h;
    if[(composeop~h 0)and any (h 1)~/:(not;fns.notsafe);
      if[(count key negated)>i:(key negated)?h 2;:argt[nm;a 0],(value negated)[i],argt[nm;a 1]]]];
  if[0h=type h;:"(",qt[nm;h],")[",(";"sv qt[nm] each a),"]"];
  if[-11h=type h;:string[h],"[",(";"sv qt[nm] each a),"]"];
  n:fnname[nm;h];
  if[(2=count a)and isinfix n;:argt[nm;a 0],$[issym n;n;" ",n," "],argt[nm;a 1]];
  if[1=count a;:n," ",argt[nm;a 0]];
  :n,"[",(";"sv qt[nm] each a),"]";
  };
/ is application x written with an operator, infix or prefix, rather than as f[args]? Its text
/ then needs brackets to be an argument
isop:{[nm;x]
  if[not (0h=type x)and 1<count x;:0b];
  if[tree.isquery x;:1b];
  h:first x;
  if[(2=count x)and any h~/:guards;:.z.s[nm;x 1]];
  if[h~enlist;:2=count x];
  if[0h=type h;:3=count h];
  if[not tree.isfn h;:0b];
  if[h~fns.findsafe;:1b];
  :(2=count x)or(3=count x)and isinfix fnname[nm;h];
  };
argt:{[nm;x] s:qt[nm;x]; :$[isop[nm;x];"(",s,")";s];};

/ a select or exec's columns: name:expression, or just the name where they are the same
qcols:{[nm;a]
  if[a~();:""];
  if[99h<>type a;:", "sv qt[nm] each a];
  :", "sv {[nm;k;v] $[v~k;string k;string[k],":",qt[nm;v]]}[nm]'[key a;value a];
  };

qquery:{[nm;x]
  upd:x[0]~tree.updop;
  t:x 1; w:tree.getc x 2; b:x 3; a:x 4;
  src:$[-11h=type t;string t;"(",qt[nm;t],")"];
  wh:$[count w;" where ",", "sv {[nm;c] s:qt[nm;c]; $[(0h=type c)and(first c)~joinop;"(",s,")";s]}[nm] each w;""];
  bys:$[99h=type b;" by ",qcols[nm;b];(0h=type b)and 0<count b;" by ",", "sv qt[nm] each b;11h=type b;" by ",", "sv string b;""];
  if[upd;
    if[11h=type a;:"delete from ",src,wh];
    if[(0h=type a)and 11h=type first a;:"delete ",(", "sv string first a)," from ",src,wh];
    :"update ",qcols[nm;a],bys," from ",src,wh];
  / a select's columns are a dictionary, or none; an exec's are an expression, by or not
  ex:not (0b~b)or(1b~b)or(99h=type b)and(99h=type a)or a~();
  ext:"";
  if[5<count x;
    ext:"[",qt[nm;x 5],$[6<count x;";",$[any (first first x 6)~/:(fns.descsafe;descop);">";"<"],qt[nm;last first x 6];""],"]"];
  :$[ex;"exec";"select",$[b~1b;" distinct";""]],ext,$[count c:qcols[nm;a];" ",c;""],bys," from ",src,wh;
  };

/ ------------------------------------------------------------------ the round trip
/ a general list that stays one, whatever its items
glist:{[r] :$[0h=type r;r;1_(::),r];};
subk:(fns.notsafe;fns.ascsafe;fns.descsafe);
subv:(not;ascop;descop);

/ x with qsp's run-time checks taken out, its guarded functions put back, and each one-item vector
/ literal written as the enlist it parses back from: what the text says
plain:{[x]
  if[99h=type x;:(key x)!glist .z.s each value x];
  if[0h<>type x;
    if[(type x) within 100 112h;:$[null i:first where subk~\:x;x;subv i]];
    if[(1=count x)and(type x) within 1 19h;if[not (type x) in 10 11h;:(enlist;first x)]];
    :x];
  if[(2=count x)and any (first x)~/:guards;:.z.s x 1];
  if[(first x)~fns.findsafe;:glist fns.findop,.z.s each x 1];
  :glist .z.s each x;
  };

/ x as q-SQL, if parsing that gives back x; else as -3! prints it, at its widest
text:{[nm;x]
  s:@[qt[nm];x;{""}];
  if[count s;if[(plain @[parse;s;{`fail}])~plain x;:s]];
  :wide x;
  };
wide:{[x] c:system"c"; system"c 25 2000"; r:@[-3!;x;{"<unrenderable>"}]; system"c "," "sv string c; :r;};

export:([text;qt;wide]);
