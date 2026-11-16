/ di.qsp.suite - a policy's own tests: tests.csv, kept beside the policy and reviewed with it
/   user,query,expect,value,note
/ each row runs a query as a user, and says what qsp must do with it:
/   rows     return at least one row
/   empty    return no rows
/   runs     return anything, rows or none
/   refused  refuse it. value, if given, is text the refusal must contain
/   equals   return exactly value, a q literal: `A1`A3`A5`A7, 12, ("a";"b"), `a`b!1 2
/ note says why, for whoever reads a failure. A policy's files say what is granted; its tests say
/ what that must mean - "llm1 never sees an account", "sales_na sees exactly A1 A3 A5 A7" - so a
/ change that keeps the files valid but breaks an intention fails the build
/ loading a test file checks its shape, and needs no data. Running one needs the tables

tree:use`..tree;
files:use`..files;

expects:`rows`empty`runs`refused`equals;

/ ------------------------------------------------------------------ the value of an equals test

/ does a parse tree hold a function anywhere?
hasfn:{[x] :$[tree.isfn x;1b;0h=type x;any .z.s each x;99h=type x;.z.s[key x]|.z.s value x;0b];};

islit:{[x]
  / is parse tree x data - written out, never computed? A name is not, nor any call but enlist
  / and ! (which build a list and a dictionary)
  t:type x;
  if[t=-11h;:0b];
  if[tree.isfn x;:0b];
  if[t<>0h;:1b];
  if[2>count x;:not hasfn x];
  h:first x;
  if[not any h~/:(enlist;!);:0b];
  :all .z.s each 1_x;
  };

/ a cell -> the value it writes, or a signal. Parsed, then evaluated only if it is plain data
literal:{[s]
  t:@[parse;s;{'"not valid q: ",x}];
  tree.chk[islit t;"an equals value must be a q literal - `a`b, 12, (\"x\";\"y\") - not an expression"];
  :eval t;
  };

/ ------------------------------------------------------------------ loading

/ one row of tests.csv -> its problem, or "" if it has none
rowproblem:{[r]
  if[0=count r`user;:"no user"];
  if[0=count r`query;:"no query"];
  e:`$r`expect;
  if[not e in expects;:"expect must be one of ",(", "sv string expects),", not ",$[count r`expect;r`expect;"blank"]];
  if[(e=`equals)and 0=count r`value;:"an equals test needs a value: the q literal it must return"];
  if[(e in `rows`empty`runs)and 0<count r`value;:"a value is only for refused (text it contains) and equals (what it returns)"];
  if[e=`equals;:@[{literal x;""};r`value;{x}]];
  :"";
  };

read:{[d]
  / (the rows of tests.csv in policy directory d; every problem with them, in line order)
  r:files.testfile d;
  t:r 0;
  e:r 1;
  if[count t;
    p:rowproblem each t;
    k:where 0<count each p;
    e,:raze files.problem[`tests.csv]'[t[`line] k;p k]];
  :(t;`line xasc e);
  };

/ every problem with the tests in policy directory d, as a table of (file;line;error). Never
/ signals: for a reviewer, or CI, to list them all - a signal's text is cut short
problems:{[d] :last read d;};

fromdir:{[d]
  / the tests in policy directory d: a table of (line;user;query;expect;value;want;note), empty if
  / there is no tests.csv. Signals if anything is wrong with the file: how much, and the first
  / problem - problems lists them all
  r:read d;
  t:r 0;
  e:r 1;
  if[count e;
    '"qsp: tests.csv in ",files.dirname[d]," has ",string[count e]," problem",$[1=count e;"";"s"],
      " - qsp.checktests lists them. The first:\n",files.problemline first e];
  / built with flip: value is a reserved word, and cannot name a column in a table literal
  :flip `line`user`query`expect`value`want`note!(t`line;`$t`user;t`query;`$t`expect;t`value;
    {$[`equals=`$x`expect;literal x`value;::]} each t;t`note);
  };

/ ------------------------------------------------------------------ judging

/ a result as a test compares it: enumerations as their symbols, a column mapped from disk as an
/ ordinary list, a keyed table unkeyed
plain:{[x]
  t:type x;
  if[t within 20 76;:value x];
  if[t within -76 -20;:value x];
  if[t within 77 97;:.z.s x til count x];
  if[t=98h;:flip .z.s each flip x];
  if[t=99h;:(.z.s key x)!.z.s value x];
  if[t=0h;:.z.s each x];
  :x;
  };

/ how many rows a result has: a table's, a list's items, one for an atom
nrows:{[x] :$[0>type x;1;99h=type x;count x;count x];};
rowtext:{[n] :string[n]," row",$[1=n;"";"s"];};

/ does string s contain t, as plain text? (like and ss read * ? [ as patterns)
contains:{[s;t]
  if[count[t]>count s;:0b];
  :any t~/:(count t)#/:(til 1+count[s]-count t)_\:s;
  };

verdict:{[t;r]
  / test t, given what running it gave - (1b;the result) or (0b;the refusal) - as (pass;what it got)
  ex:t`expect;
  if[not r 0;
    m:r 1;
    if[ex=`refused;:((0=count t`value)or contains[m;t`value];m)];
    :(0b;m)];
  v:plain r 1;
  n:nrows v;
  if[ex=`refused;:(0b;"ran, and returned ",rowtext n)];
  if[ex=`rows;:(n>0;rowtext n)];
  if[ex=`empty;:(n=0;rowtext n)];
  if[ex=`runs;:(1b;rowtext n)];
  / shown without an attribute: ~ ignores one, so `s#`a`b reads as a mismatch it is not
  :(v~t`want;"returned ",200 sublist -3!$[(type v) within 0 19;`#v;v]);
  };

export:([expects;fromdir;problems;verdict;plain;literal]);
