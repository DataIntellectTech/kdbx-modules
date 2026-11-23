/ di.qsp.policy.files - a policy kept as files
/ a directory of CSVs is a policy in a form a permissions team can edit in a spreadsheet and
/ review in a pull request. fromfiles reads it into a policy value - the same value the builders
/ return - so nothing downstream knows or cares where a policy came from
/   tables.csv     tbl,partition                  required
/   grants.csv     entity,tbl,columns,filter      required
/   members.csv    user,entity
/   gateways.csv   login
/   functions.csv  action,name                    action: allow deny call joincall
/   config.csv     setting,value
/   schema.csv     tbl,col,typ,att                tables not loaded in this process
/ and beside them, not part of the policy:
/   tests.csv      user,query,expect,value,note   what the policy must do (suite.q)
/ lines that are blank or start with # are ignored. Every row is checked, and every problem in
/ every file is reported at once with its file and line, so a broken policy is fixed in one pass
/ rather than one error at a time. A policy with any problem does not load: there is no
/ partly-applied policy
/ the files are as sensitive as q code - a filter cell is q that runs inside every query it
/ applies to. Keep them where changes are reviewed

tree:use`...core.tree;
fns:use`...core.fns;
pol:use`...policy;
f:use`..f;

/ file -> its header, in the order the files are applied. (Built with !, as tables is a reserved
/ word and cannot be a key in a dictionary literal.)
files:`config`functions`schema`tables`grants`members`gateways`terms!(
  `setting`value;`action`name;`tbl`col`typ`att`bytes`description;`tbl`partition`mingroup;
  `entity`tbl`columns`filter;`user`entity;`login`users;`term`meaning`formula`q`tables`caveat`params`example);
required:`tables`grants;
/ files a policy directory holds that are not the policy, and how many of their fields a row must
/ have: the rest may be left off
others:(enlist`tests)!enlist `user`query`expect`value`note;
/ schema.csv's bytes and description are optional, and a schema.csv written before they existed -
/ tbl,col,typ,att - still loads: a header may stop after the fields every row needs
least:`tests`schema`terms`gateways`tables!3 4 2 1 2;
headers:files,others;

/ ------------------------------------------------------------------ paths

dirname:{[d]
  / a policy directory as a string, without a leading colon or a trailing slash
  tree.chk[(10h=type d)or -11h=type d;"a policy directory is a string or a file symbol"];
  s:$[10h=type d;d;string d];
  if[":"=first s;s:1_s];
  :$["/"=last s;-1_s;s];
  };
path:{[d;n] :hsym `$dirname[d],"/",string[n],".csv";};

/ ------------------------------------------------------------------ reading
/ q's own CSV reader is not used: it pads a short row with blanks and drops the extra fields of a
/ long one, without a word. A policy file with a cell in the wrong column must be an error, not a
/ different policy

noerrors:([]file:`symbol$();line:`long$();error:());
problem:{[f;l;m] :([]file:enlist f;line:enlist l;error:enlist $["qsp: "~5#m;5_m;m]);};

/ Excel's "CSV UTF-8" starts with one
bom:"\357\273\277";

/ a field, trimmed, and unquoted as a spreadsheet quotes it: "" inside a quoted field is a quote
unquote:{[c]
  s:trim c;
  :$[(1<count s)and("\""=first s)and"\""=last s;ssr[1_-1_s;"\"\"";"\""];s];
  };

fields:{[l]
  / one line -> its fields, trimmed. A quoted field may hold commas, and "" for a quote, as a
  / spreadsheet writes them. A quote must close on its own line
  q:l="\"";
  tree.chk[0=(sum q)mod 2;"unterminated quote - a quoted cell must close on the same line"];
  c:where (l=",")&0=(sums q)mod 2;
  v:(0,1+c) cut l;
  v:@[v;til count c;-1_];
  :unquote each v;
  };

/ trailing empty fields - a spreadsheet pads every row to its widest
untrail:{[v] :v where not reverse mins reverse 0=count each v;};

readrow:{[h;m;x]
  / one data line -> (1b;fields) or (0b;why not), for a file with header h whose rows need at
  / least m fields
  r:@[{(1b;fields x)};x;{(0b;x)}];
  if[not r 0;:r];
  v:r 1;
  n:count h;
  if[n<count v;if[0=count untrail n _v;v:n#v]];
  if[(m<=count v)and n>count v;v:n#v,n#enlist""];
  if[not n=count v;:(0b;"expected ",string[n]," fields (",(","sv string h),"), found ",string count v)];
  :(1b;v);
  };

/ a header line -> its names, or ` if it cannot be read
header:{[l] :@[{`$untrail fields x};l;{`}];};

readfile:{[d;n]
  / one file -> (rows; problems; fatal). rows is a table of strings with the line each came
  / from. fatal: the file as a whole cannot be used
  h:headers n;
  m:$[n in key least;least n;count h];
  nm:`$string[n],".csv";
  empty:([]line:`long$()),flip h!(count h)#enlist ();
  if[()~key p:path[d;n];
    :$[n in required;(empty;problem[nm;0;"missing ",string nm];1b);(empty;noerrors;0b)]];
  r:@[{(1b;read0 x)};p;{(0b;x)}];
  if[not r 0;:(empty;problem[nm;0;"cannot read ",string[nm],": ",r 1];1b)];
  l:r 1;
  if[count l;if[bom~3#first l;l[0]:3_first l]];
  i:where not {(0=count x)or"#"=first x} each trim each l;
  if[0=count i;:(empty;problem[nm;0;string[nm]," has no header line"];1b)];
  got:header l first i;
  if[not $[11h=type got;(m<=count got)&got~(count got)#h;0b];
    :(empty;problem[nm;1+first i;"header must be ",(","sv string h),
      " - found ",$[11h=type got;","sv string got;"an unreadable line"]];1b)];
  j:1_i;
  rs:readrow[h;m] each l j;
  ok:rs[;0];
  e:noerrors,raze problem[nm]'[1+j where not ok;rs[where not ok;1]];
  t:$[any ok;([]line:1+j where ok),'flip h!flip rs[where ok;1];empty];
  :(t;e;0b);
  };

sym:{[s] :`$trim s;};

/ ------------------------------------------------------------------ cells

undefinedfn:{[n;e]
  '"fn:",string[n]," is not defined in this process - load the q that defines it first (\\l it, ",
    "or -init it for bin/policy.q)"};

/ the value of a fn:name cell, which must be defined in this process
namedfn:{[s]
  n:sym 3_s;
  tree.chk[not null n;"fn: needs the name of a function"];
  :(n;@[get;n;undefinedfn n]);
  };

filter:{[s]
  / a filter cell -> what grant takes:
  /   (blank)               no row restriction
  /   fn:name               the unary function `name`, called with the user on every query - for
  /                         what a where clause cannot say
  /   a q where clause      e.g.  account in `A1`A2, size>100
  /                         qsp.USER  the user the query runs as
  /                         qsp.NOW   the policy clock
  /                         qsp.aged[time;0D00:15]  rows at least 15 minutes old
  / the where clause is parsed, never evaluated, when the policy loads
  if[0=count s;:()];
  if[s like "fn:*";:filterfn s];
  w:@[parse;"select from qspfilter where ",s;{'"filter is not valid q: ",x}];
  tree.chk[(5=count w)and(tree.selop~first w)and(`qspfilter~w 1)and(0b~w 3)and()~w 4;
    "filter must be a where clause only"];
  :markers each tree.getc w 2;
  };

filterfn:{[s]
  / a fn:name filter cell: a function of one argument, the user
  nv:namedfn s;
  n:string nv 0;
  v:nv 1;
  tree.chk[100h=type v;"fn:",n," must be a function of one argument, the user"];
  tree.chk[1=count (value v)1;"fn:",n," must take exactly one argument, the user"];
  :v;
  };

/ a qsp.* name in a filter -> the marker the policy resolves
markersym:{[x]
  if[x=`qsp.USER;:tree.usermark];
  if[x=`qsp.NOW;:tree.nowmark];
  tree.chk[not x like "qsp.*";"unknown name in filter: ",string x];
  :x;
  };

markers:{[x]
  / the qsp.* names a filter may use -> the markers the policy resolves
  if[-11h=type x;:markersym x];
  if[(11h=type x)and 1<count x;:.z.s each x];
  if[0h<>type x;:x];
  if[0=count x;:x];
  if[`qsp.aged~first x;
    tree.chk[3=count x;"qsp.aged takes a column and a timespan: qsp.aged[time;0D00:15]"];
    :f.aged[x 1;x 2]];
  / not, as the walker would substitute it in a query (fns.q)
  if[(fns.resolve`not)~first x;:fns.notsafe,.z.s each 1_x];
  :.z.s each x;
  };

literal:{[k;s]
  / a config cell -> a q literal. Never evaluated: a name, an expression or a lambda is refused,
  / so a config file cannot run code. clock takes fn:name
  tree.chk[count s;"no value"];
  if[s like "fn:*";:literalfn s];
  v:@[parse;s;{'"not a q literal: ",x}];
  / parse wraps a symbol constant in enlist; a bare name, or names side by side (which parse as
  / a call), are not literals
  tree.chk[not -11h=type v;"not a literal: ",s," - a symbol is written `",s];
  tree.chk[not (11h=type v)and 1<count v;"not a literal: ",s];
  tree.chk[not tree.isfn v;"a function is given by name, as fn:name"];
  v:$[(11h=type v)and 1=count v;first v;
    (0h=type v)and(1=count v)and 11h=type first v;first v;
    v];
  tree.chk[not (0h=type v)or tree.isfn v;"must be a literal value, not an expression"];
  if[(11h=type pol.defaultconfig k)and -11h=type v;v:enlist v];
  :v;
  };

literalfn:{[s]
  / a fn:name config cell: any function
  nv:namedfn s;
  tree.chk[tree.isfn nv 1;"fn:",string[nv 0]," is not a function"];
  :nv 1;
  };

/ ------------------------------------------------------------------ applying
/ each row is applied to the policy built so far. A row that fails leaves it unchanged and adds
/ its error; later rows still run, so one load reports everything

configrow:{[p;r]
  / one row of config.csv
  tree.chk[0=r`earlier;"setting repeated - first set on line ",string r`earlier];
  k:sym r`setting;
  tree.chk[k in key pol.defaultconfig;"unknown setting: ",string[k]," - one of ",", "sv string key pol.defaultconfig];
  :pol.configure[p;(enlist k)!enlist literal[k;r`value]];
  };

functionrow:{[p;r]
  / one row of functions.csv
  a:sym r`action;
  n:sym r`name;
  tree.chk[not null n;"no function name"];
  tree.chk[a in `allow`deny`call`joincall;"action must be allow, deny, call or joincall"];
  :(`allow`deny`call`joincall!(pol.allowfunction;pol.denyfunction;pol.allowcall;pol.allowjoincall))[a][p;n];
  };

/ is t a table loaded in this process - in memory, splayed or partitioned?
loaded:{[t] :1b~@[{.Q.qt get x};t;0b];};

/ schema.csv rows -> a meta table
asmeta:{[s] :([c:`$s`col] t:{$[count x;first x;" "]} each s`typ; f:count[s]#`; a:`$s`att);};

/ register table t from this process, or from its schema.csv rows s
registertable:{[p;t;s]
  if[loaded t;:pol.table[p;t;::]];
  tree.chk[count s;string[t]," is not loaded in this process and schema.csv does not describe it"];
  :pol.table[p;t;asmeta s];
  };

tablerow:{[sc;p;r]
  / one row of tables.csv; sc is every row of schema.csv
  t:sym r`tbl;
  tree.chk[not null t;"no table name"];
  tree.chk[not pol.known[p;t];"table ",string[t]," is listed twice"];
  p:registertable[p;t;sc where sc[`tbl]~\:string t];
  / mingroup, optional: the fewest rows an aggregate testing hidden columns must summarise
  if[`mingroup in key r;if[count m:trim r`mingroup;
    k:"J"$m;
    tree.chk[not null k;"mingroup must be a whole number of rows, not ",m];
    p:pol.mingroup[p;t;k]]];
  if[null pc:sym r`partition;:p];
  if[null c:p[`tabs;t];:pol.partition[p;t;pc]];
  tree.chk[c=pc;string[t]," is partitioned on ",string[c],", not ",string pc];
  :p;
  };

grantrow:{[p;r]
  / one row of grants.csv
  e:sym r`entity;
  t:sym r`tbl;
  tree.chk[not null e;"no entity - name a user or group, or delete the row"];
  tree.chk[not null t;"no table"];
  tree.chk[0=r`earlier;string[e]," is already granted ",string[t]," on line ",string[r`earlier],
    " - one row per entity and table; combine filters with or"];
  c:$[(enlist"*")~r`columns;pol.allcols;`$" " vs r`columns];
  if[11h=type c;c:c where not null c];
  tree.chk[count c;"no columns - list them separated by spaces, or * for all"];
  :pol.grant[p;e;t;c;filter r`filter];
  };

memberrow:{[p;r]
  / one row of members.csv
  u:sym r`user;
  e:sym r`entity;
  tree.chk[not null u;"no user"];
  tree.chk[not null e;"no entity"];
  :pol.member[p;u;e];
  };

termrow:{[p;r]
  / one row of terms.csv: tables separated by spaces
  n:sym r`term;
  tree.chk[not null n;"no term"];
  tree.chk[0=r`earlier;string[n]," is already defined on line ",string r`earlier];
  ts:`$" " vs trim r`tables;
  p:pol.term[p;n;r`meaning;r`formula;r`q;ts where not null ts;$[`caveat in key r;r`caveat;""]];
  / params and example are optional: a terms.csv written before they existed still loads
  ps:$[`params in key r;trim r`params;""];
  :$[count ps;pol.paramterm[p;n;ps;$[`example in key r;trim r`example;""]];p];
  };

gatewayrow:{[p;r]
  / one row of gateways.csv
  tree.chk[not null g:sym r`login;"no login"];
  p:pol.gateway[p;g];
  / users: the group this gateway may name users from; empty for any user
  grp:$[`users in key r;sym r`users;`];
  :$[null grp;p;pol.scopegateway[p;g;grp]];
  };

/ schema.csv changes nothing by itself: its rows are checked here, and used by tablerow for a
/ table this process does not hold
types:" bgxhijefcspmdznuvtBGXHIJEFCSPMDZNUVT";

schemarow:{[p;r]
  / one row of schema.csv
  tree.chk[not null sym r`tbl;"no table"];
  tree.chk[not null sym r`col;"no column"];
  tree.chk[(1>=count r`typ)and all (r`typ) in types;
    "type must be one meta type character such as j, s or p - found ",r`typ];
  tree.chk[(sym r`att) in ``p`u`g`s;"attribute must be blank, p, u, g or s - found ",r`att];
  tree.chk[isbytes r`bytes;"bytes must be blank or a number of bytes per row, not negative - found ",r`bytes];
  tree.chk[0=r`earlier;string[sym r`col]," of ",string[sym r`tbl]," is already described on line ",string r`earlier];
  :p;
  };

/ a schema.csv bytes cell: blank, or a number not below 0
isbytes:{[b] :$[0=count trim b;1b;(not null f)&0<=f:"F"$trim b];};

colinforow:{[p;r]
  / a schema.csv row's size and description, for a table registered by now. A column the
  / loaded table lacks is left for schemadrift to report
  t:sym r`tbl; c:sym r`col;
  if[not pol.known[p;t];:p];
  if[not c in pol.columnsof[p;t];:p];
  b:$[0=count trim r`bytes;0n;"F"$trim r`bytes];
  :pol.colinfo[p;t;c;b;r`description];
  };

/ the line of an earlier row with the same key, or 0 - for rows where a repeat would silently
/ replace the first
earlier:{[t;k] fi:k?k; :t,'([]earlier:(0,t`line)(fi<til count t)*1+fi);};

/ fn applied to p and r, as (1b;new policy) or (0b;why not)
applyrow:{[fn;p;r] :(1b;fn[p;r]);};
tryrow:{[fn;p;r] :@[applyrow[fn;p];r;{(0b;x)}];};

step:{[n;fn;s;r]
  / s is (policy;errors). Apply fn to row r, recording a failure against file n
  x:tryrow[fn;s 0;r];
  if[x 0;:(x 1;s 1)];
  m:tree.clean x 1;
  :(s 0;s[1],([]file:enlist `$string[n],".csv";line:enlist r`line;error:enlist $["qsp: "~5#m;5_m;m]));
  };

unknownfile:{[n] :problem[n;0;"unknown file - a policy directory holds only ",", "sv string[key headers],\:".csv"];};

build:{[d]
  / (policy; errors) for a directory
  dn:dirname d;
  k:key hsym `$dn;
  if[0h=type k;:(pol.new[];problem[`;0;"no policy directory at ",dn])];
  if[-11h=type k;:(pol.new[];problem[`;0;dn," is a file, not a policy directory"])];
  / a misspelt file name would otherwise be skipped as an absent optional file
  e:noerrors,raze unknownfile each k where (k like "*.csv")and not k in `$(string key headers),\:".csv";
  rd:readfile[d] each key files;
  fs:(key files)!rd[;0];
  e,:raze rd[;1];
  if[any rd[;2];:(pol.new[];e)];
  :applyfiles[fs;(pol.new[];e)];
  };

applyfiles:{[fs;s]
  / apply the rows of every file, in order, to s: (policy; errors)
  s:step[`config;configrow]/[s;earlier[fs`config;sym each fs[`config]`setting]];
  s:step[`functions;functionrow]/[s;fs`functions];
  s:step[`schema;schemarow]/[s;earlier[fs`schema;{(sym x`tbl;sym x`col)} each fs`schema]];
  s:step[`tables;tablerow[fs`schema]]/[s;fs`tables];
  / a row whose size was refused above is already reported
  s:step[`schema;colinforow]/[s;fs[`schema] where {(isbytes x`bytes)&0<count[trim x`bytes]+count trim x`description} each fs`schema];
  g:earlier[fs`grants;{(sym x`entity;sym x`tbl)} each fs`grants];
  / a table whose own row failed is already reported: its grants would only repeat that as
  / "unregistered table", once per grant
  broken:(sym each fs[`tables]`tbl) except key s[0]`tabs;
  s:step[`grants;grantrow]/[s;g where not (sym each g`tbl) in broken];
  s:step[`members;memberrow]/[s;fs`members];
  s:step[`gateways;gatewayrow]/[s;fs`gateways];
  :step[`terms;termrow]/[s;earlier[fs`terms;sym each fs[`terms]`term]];
  };

/ every problem with the policy in directory d - empty when it would load
check:{[d] :last build d;};

/ ------------------------------------------------------------------ drift
/ a table loaded in this process is registered from its live meta, and schema.csv is read only for
/ a table that is not loaded. So the policy CI checks against schema.csv and the policy a running
/ process enforces can differ, and nothing would say so

/ where schema.csv rows s and loaded table tn disagree, in words
tabledrift:{[tn;s]
  m:0!meta tn;
  lc:m`c;
  sc:sym each s`col;
  pre:string[tn],": column ";
  r:(pre,/:string[sc except lc],\:" is in schema.csv but not the loaded table"),
    pre,/:string[lc except sc],\:" is in the loaded table but not schema.csv";
  both:sc inter lc;
  st:(sc!{$[count x;first x;" "]} each trim each s`typ) both;
  lt:(lc!m`t) both;
  k:where (st<>" ")&st<>lt;
  r,:{[tn;c;a;b] string[tn],".",string[c],": type ",a," in schema.csv, ",b," loaded"}[tn]'[both k;enlist each st k;enlist each lt k];
  sa:(sc!sym each s`att) both;
  la:(lc!m`a) both;
  k:where sa<>la;
  r,:{[tn;c;a;b] string[tn],".",string[c],": attribute ",$[null a;"none";string a]," in schema.csv, ",$[null b;"none";string b]," loaded"}[tn]'[both k;sa k;la k];
  :r;
  };

/ every difference between schema.csv in policy directory d and the tables loaded in this process
schemadrift:{[d]
  rf:readfile[d;`schema];
  if[rf 2;:()];
  s:rf 0;
  ts:distinct sym each s`tbl;
  ts:ts where loaded each ts;
  :raze {[s;t] tabledrift[t;s where (sym each s`tbl)=t]}[s] each ts;
  };

/ one problem, as a line of a refusal
problemline:{[x] :"  ",string[x`file],$[x`line;":",string x`line;""],": ",x`error;};

/ the policy in directory d, or a refusal listing every problem with it - fromfiles without its
/ warnings, for a caller that reads schemadrift itself
policyin:{[d]
  r:build d;
  if[count e:r 1;
    '"qsp: policy in ",dirname[d]," has ",string[count e]," problem",$[1=count e;"";"s"],":\n",
      "\n" sv problemline each e];
  :r 0;
  };

fromfiles:{[d]
  / the policy in directory d, or a refusal listing every problem with it
  p:policyin d;
  / the loaded tables win, so a stale schema.csv is a warning, not a refusal
  {-2"qsp: warning: ",x," - the loaded table is enforced; update schema.csv";} each schemadrift d;
  :p;
  };

/ ------------------------------------------------------------------ scaffold

/ write table t into file n of policy directory d
writefile:{[d;n;t] path[d;n] 0: csv 0: t;};
/ ------------------------------------------------------------------ column sizes
/ bytes per row of each column, as -22! counts a result - what maxsize checks - measured on a
/ sample, so a query's size can be estimated before it runs: rows times the bytes of the columns
/ it returns. A fixed-width column is its width (date and int 4, float and timestamp 8), but a
/ symbol is sent as its text, so its size is its values' - 2 bytes for a venue code, 21 for an
/ order id - and has to be measured

/ up to n rows of table t loaded here: of its latest partition, read by row index so that a day
/ of quotes is not read whole, or of the table
sample:{[t;n]
  v:get t;
  if[not 1b~.Q.qp v;:n sublist v];
  c:.Q.cn v;
  :.Q.ind[v;(sum -1_c)+til n&last c];
  };

/ column -> bytes per row, to 0.1, for table t loaded here: from up to n rows. 0n for every
/ column of an empty table
measure:{[t;n]
  s:sample[t;n];
  cs:cols s;
  if[0=count s;:cs!(count cs)#0n];
  / less the column's fixed overhead - its size with no rows - which a small table would
  / otherwise spread over a few rows
  :cs!{[s;c] v:?[s;();0b;(enlist c)!enlist c]; 0.1*floor 0.5+10*((-22!v)-(-22!0#v))%count s}[s] each cs;
  };

/ how many rows measure samples
measuren:100000;

/ schema.csv rows for table t with meta m: its columns, types and attributes, the bytes measured
/ if it is loaded here, and no description
schemarows:{[t;m]
  b:$[loaded t;measure[t;measuren];()!()];
  :([]tbl:(count m)#t;col:m`c;typ:enlist each m`t;att:m`a;bytes:{$[null x;"";string x]} each b m`c;
    description:(count m)#enlist"");
  };

/ schema.csv in directory d with its bytes measured again from the tables loaded here: every other
/ field, the descriptions, and the rows of tables not loaded, are kept. Returns what changed, as
/ ([]tbl;col;was;now) - bytes moving by more than a quarter is the data changing shape
remeasure:{[d]
  r:readfile[d;`schema];
  tree.chk[not r 2;"schema.csv cannot be read: ",.Q.s1 r 1];
  t:delete line from r 0;
  ts:distinct sym each t`tbl;
  ts:ts where loaded each ts;
  m:ts!measure[;measuren] each ts;
  now:{[m;t;c] $[(t in key m)and c in key m t;$[null b:m[t;c];"";string b];`keep]}[m]'[sym each t`tbl;sym each t`col];
  k:where not now~\:`keep;
  was:t[`bytes]k;
  t:@[t;`bytes;:;@[t`bytes;k;:;now k]];
  writefile[d;`schema;t];
  ch:([]tbl:sym each t[`tbl]k;col:sym each t[`col]k;was:"F"$was;now:"F"$now k);
  :select from ch where not was=now;
  };
/ the partition column of a table loaded here, or `
partitionof:{[t] :$[1b~.Q.qp get t;.Q.pf;`];};

/ the directory a policy directory d sits in, as a string
parentof:{[d]
  s:dirname d;
  if["/"<>first s;s:system["cd"],"/",s];
  :$[0=i:last where s="/";"/";i#s];
  };
/ whether directory p is a database q loads: a par.txt, a partition directory, or a splayed
/ table. q loads every directory in a database as a table, so a policy directory written there
/ stops the database loading - 'parse on its first csv. An HDB console's working directory is the
/ database, so a relative scaffold["policy";...] there would land in it. Partition names are
/ matched by shape, so a large HDB is not listed directory by directory
isdatabase:{[p]
  if[11h<>type k:key h:hsym`$p;:0b];
  if[`par.txt in k;:1b];
  s:string k;
  pn:(s like "[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]")or(s like "[0-9][0-9][0-9][0-9].[0-9][0-9]")or
    {(0<count x)and all x in .Q.n} each s;
  isdir:@[{11h=type key x};;0b];
  if[any isdir each ` sv/:h,/:k where pn;:1b];
  :any @[{`.d in key x};;0b] each ` sv/:h,/:k where not pn;
  };

scaffold:{[d;ts]
  / write a starting policy for tables ts (` for every table in this process) into directory d:
  / every table, partition column and column, and one grant row per table listing all its
  / columns with no entity. That row does not load until someone names who it is for, or
  / deletes it - so nothing is granted by default. Refuses to overwrite an existing policy
  ts:$[ts~`;tables`.;(),ts];
  tree.chk[count ts;"no tables to scaffold"];
  l:loaded each ts;
  tree.chk[all l;"not a table in this process: ",", "sv string ts where not l];
  p:parentof d;
  tree.chk[not isdatabase p;"refusing to write into ",p,", a database: q loads every ",
    "directory there as a table, so the database would no longer load. Write the policy beside it"];
  there:(key files) where {not ()~key x} each path[d] each key files;
  tree.chk[0=count there;"refusing to overwrite ",", "sv string[there],\:".csv"];
  m:{0!meta x} each ts;
  writefile[d;`tables;([]tbl:ts;partition:partitionof each ts)];
  writefile[d;`schema;raze schemarows'[ts;m]];
  writefile[d;`grants;([]entity:(count ts)#enlist"";tbl:ts;columns:{" "sv string x`c} each m;filter:(count ts)#enlist"")];
  writefile[d;`members;([]user:`symbol$();entity:`symbol$())];
  writefile[d;`gateways;([]login:`symbol$())];
  writefile[d;`functions;([]action:`symbol$();name:`symbol$())];
  / no terms yet: the header, for whoever knows the business to fill in
  writefile[d;`terms;flip (files`terms)!(count files`terms)#enlist ()];
  c:(enlist`clock)_pol.defaultconfig;
  writefile[d;`config;flip `setting`value!(key c;{-3!x} each value c)];
  :path[d] each key files;
  };

/ tests.csv in directory d -> (its rows, as strings with the line each is on; the problems)
testfile:{[d] r:readfile[d;`tests]; :(r 0;r 1);};

export:([fromfiles;policyin;check;scaffold;files;schemadrift;testfile;problem;problemline;dirname;
  measure;remeasure;schemarows;readfile]);
