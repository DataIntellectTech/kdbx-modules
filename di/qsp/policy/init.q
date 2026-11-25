/ di.qsp.policy - a policy is a value
/ every builder takes a policy and returns a new one; nothing here writes a global. A policy can
/ therefore be built in a script, compared, kept beside another one, handed to qsp.run directly,
/ or installed with qsp.serve - and replacing the served policy is a single atomic swap rather
/ than a sequence of mutations a query could observe half-done
/ a policy is a dictionary:
/   tabs      table -> partition column (` if none)
/   schema    ([]tbl;col;typ;att)     every registered column, in order
/   grants    ([]entity;tbl;columns;rows)
/   members   ([]user;entity)         users in groups, groups in groups
/   fns       name -> value           the function whitelist
/   calls     names callable by name (trusted - see allowcall)
/   joincalls the subset whose result carries its arguments' columns
/   gateways  logins allowed to assert another user's identity
/   config    see defaultconfig

tree:use`..core.tree;
fns:use`..core.fns;

/ every column, in a grant
allcols:`$"*";
temporal:"pmdznuvt";

/ configuration, with its defaults. configure refuses an unknown key or a value of the wrong
/ type: a typo in a policy must never quietly open it up
defaultconfig:([
  selectonly:1b;          / innermost table access must be a select
  strictcolumns:1b;       / where clauses may only use visible columns
  placement:`auto;        / where the row filter goes: `auto`first`last
  attributerank:`p`u`g`s; / index attributes, best first
  rowindex:0b;            / may the virtual column i be used at all
  clock:{[] .z.p};        / "now", for aged filters and NOW
  maxdepth:24;            / parse tree nesting limit
  maxsize:200000000;      / max result size, bytes
  maxrows:0W;             / max rows returned
  requirepartition:0b;    / refuse a scan of every partition
  maxpartitions:0W;       / refuse a query that would read more partitions than this
  audit:1b;               / record every decision
  auditmax:10000]);       / rows kept in the audit log

chkname:{[n;what] tree.chk[(-11h=type n)and not null n;what," name must be a non-null symbol"];};
known:{[p;t] :t in key p`tabs;};
chkknown:{[p;t] tree.chk[known[p;t];"unregistered table ",string t];};

new:{[]
  / an empty policy: it denies everything
  :([
    tabs:(`symbol$())!`symbol$();
    schema:([]tbl:`symbol$();col:`symbol$();typ:"";att:`symbol$());
    grants:([]entity:`symbol$();tbl:`symbol$();columns:();rows:());
    members:([]user:`symbol$();entity:`symbol$());
    fns:fns.defaults;
    calls:`symbol$();
    joincalls:`symbol$();
    gateways:`symbol$();
    config:defaultconfig]);
  };

/ ------------------------------------------------------------------ tables

/ meta, as (col;typ;att) rows
frommeta:{[m] m:0!m; :([]col:m`c;typ:m`t;att:m`a);};
readpartition:{[t] :$[1b~@[.Q.qp;@[get;t;()];0b];.Q.pf;`];};
metaerror:{[t;e] '"qsp: cannot read the meta of ",string[t]," - ",e};
/ (col;typ;att) rows for bare column names: nothing is known about types or indexes
fromnames:{[c] c:(),c; :([]col:c;typ:count[c]#" ";att:count[c]#`);};

/ (col;typ;att) rows from a table spec: see table
fromspec:{[t;spec]
  if[spec~(::);:frommeta @[meta;t;metaerror t]];
  if[11h=abs type spec;:fromnames spec];
  if[99h=type spec;:frommeta spec];
  tree.chk[0b;"table spec must be ::, a meta table or a list of column names"];
  };

table:{[p;t;spec]
  / register a table. spec is one of:
  /   ::           read columns, types, attributes and partition column from the live table -
  /                what you want on an RDB or HDB
  /   meta t       a meta table, for a process where t is not loaded (a gateway); describe its
  /                partition column with partition
  /   `a`b`c       bare column names; nothing is known about types or indexes
  / a column added to the table later stays invisible until refresh: the fail-closed direction
  chkname[t;"table"];
  s:fromspec[t;spec];
  tree.chk[count s;"table ",string[t]," has no columns"];
  pc:$[spec~(::);readpartition t;`];
  / keep a partition set by hand
  if[null pc;pc:p[`tabs;t]];
  if[not pc in s`col;pc:`];
  p[`schema]:(delete from p[`schema] where tbl=t),`tbl xcols update tbl:t from s;
  p[`tabs;t]:pc;
  :p;
  };

partition:{[p;t;c]
  / name the partition column of a table described by hand
  chkknown[p;t];
  tree.chk[c in columnsof[p;t];string[c]," is not a column of ",string t];
  p[`tabs;t]:c;
  :p;
  };

/ re-read table t if it is loaded in this process; leave it alone if not
refreshone:{[p;t] :@[table[;t;::];p;p];};
/ re-read every table that is loaded in this process; leave the rest
refresh:{[p] :refreshone/[p;key p`tabs];};

droptable:{[p;t]
  / unregister a table, and its grants
  p[`tabs]:(enlist t)_p`tabs;
  p[`schema]:delete from p[`schema] where tbl=t;
  p[`grants]:delete from p[`grants] where tbl=t;
  :p;
  };

columnsof:{[p;t] :exec col from p[`schema] where tbl=t;};

info:{[p;t]
  / what the walker and the orderer need to know about one table
  s:select from p[`schema] where tbl=t;
  a:exec col!att from s where not null att;
  :([columns:s`col;types:s[`col]!s`typ;attributes:a;partition:p[`tabs;t]]);
  };

/ ------------------------------------------------------------------ grants

/ every function value in a parse tree
fnvalues:{[x] :$[tree.isfn x;enlist x;(type x) in 0 98 99h;raze .z.s each tree.items x;()];};
/ a function value, named for a message
fnlabel:{[v] :$[null n:fns.name v;-3!v;string n];};
/ can name n be read in this process?
defined:{[n] :@[{get x;1b};n;0b];};

chkfilter:{[p;t;f]
  / check a static row filter now, as a grant is made; a lambda's result is checked per query
  l:normfilter f;
  resolve[p;`qsp;t;] each l;
  / nothing on the never list, in a filter any more than in a query
  v:fnvalues l;
  v:v where fns.never each v;
  tree.chk[0=count v;"filter uses ",(", "sv fnlabel each v),", which is never permitted"];
  / every name a filter reads must be a column, or defined here - a misspelt column otherwise
  / refuses every query the grant covers
  n:distinct (raze tree.namerefs each l) except (tree.agedmark;tree.usermark;tree.nowmark),columnsof[p;t];
  bad:n where not defined each n;
  tree.chk[0=count bad;"filter names ",(", "sv string bad),", neither a column of ",string[t]," nor defined"];
  };

grant:{[p;e;t;c;f]
  / grant an entity (a user or a group) columns and rows of a table
  /   c - a symbol list, or allcols (qsp.ALL)
  /   f - () for no row restriction, a list of constraints (see qsp.f), or a unary lambda taking
  /       the user and returning a list of constraints, or qsp.ALL for no restriction, called per
  /       query. A lambda's empty result refuses the query
  / several grants on one table union their columns and OR their row filters
  chkname[e;"entity"];
  chkknown[p;t];
  tree.chk[(c~allcols)or 11h=abs type c;"columns must be a symbol list or qsp.ALL"];
  / a misspelt column grants nothing, quietly: refuse it instead
  bad:$[c~allcols;`symbol$();((),c) except columnsof[p;t]];
  tree.chk[0=count bad;"no column ",(", "sv string bad)," in ",string t];
  if[not 100h=type f;chkfilter[p;t;f]];
  p:revoke[p;e;t];
  p[`grants],:([]entity:enlist e;tbl:enlist t;columns:enlist (),c;rows:enlist f);
  :p;
  };

revoke:{[p;e;t] p[`grants]:delete from p[`grants] where entity=e,tbl=t; :p;};

member:{[p;u;e]
  / put a user in a group, or a group in a group
  chkname[u;"user"];
  chkname[e;"entity"];
  if[not count select from p[`members] where user=u,entity=e;
    p[`members],:([]user:enlist u;entity:enlist e)];
  :p;
  };
unmember:{[p;u;e] p[`members]:delete from p[`members] where user=u,entity=e; :p;};

/ ------------------------------------------------------------------ functions

allowfunction:{[p;ns] p[`fns],:fns.catalog ns; :p;};
denyfunction:{[p;ns] p[`fns]:((),ns)_p`fns; :p;};

/ a function callable by name (parse leaves a call to a user function as a symbol). Trusted: qsp
/ checks the call site, not the body - expose only what cannot itself read or write what the
/ caller should not see
allowcall:{[p;ns] p[`calls]:distinct p[`calls],(),ns; :p;};

/ a join-like call - one whose result carries exactly the columns of the tables passed to it,
/ such as an aj wrapper - may stand in a select's table slot, and the select above may name the
/ columns its arguments project
allowjoincall:{[p;ns] p:allowcall[p;ns]; p[`joincalls]:distinct p[`joincalls],(),ns; :p;};

denycall:{[p;ns]
  / remove functions from both call lists
  p[`calls]:p[`calls] except (),ns;
  p[`joincalls]:p[`joincalls] except (),ns;
  :p;
  };

/ logins (a gateway's) that may run a query as another, named user
gateway:{[p;us] p[`gateways]:distinct p[`gateways],(),us; :p;};

/ is v a valid value for setting k?
settingok:{[k;v] :$[k=`clock;tree.isfn v;(type v)=type defaultconfig k];};

configure:{[p;d]
  / change settings, refusing an unknown key or a value of the wrong type
  tree.chk[99h=type d;"configure takes a dictionary"];
  bad:(key d) except key defaultconfig;
  tree.chk[0=count bad;"unknown setting: ",", " sv string bad];
  bad:(key d) where not settingok'[key d;value d];
  tree.chk[0=count bad;"wrong type for setting: ",", " sv string bad];
  if[`placement in key d;
    tree.chk[d[`placement] in `auto`first`last;"placement must be `auto, `first or `last"]];
  p[`config]:p[`config],d;
  :p;
  };

/ ------------------------------------------------------------------ resolution

/ the entities r, and every entity they are members of
inherit:{[p;r] :distinct r,exec entity from p[`members] where user in r;};
/ every entity a user inherits from, following nesting; a cycle converges like any other group
entitiesfor:{[p;u] :inherit[p]/[(),u];};

grantsfor:{[p;u;t] e:entitiesfor[p;u]; :select from p[`grants] where entity in e,tbl=t;};

/ the columns of a that grant columns c gives
grantcols:{[a;c] :$[allcols in c;a;a inter c];};

columnsfor:{[p;u;t]
  / the columns user u may see on table t
  if[not known[p;t];:`symbol$()];
  if[0=count g:grantsfor[p;u;t];:`symbol$()];
  :distinct raze grantcols[columnsof[p;t]] each g`columns;
  };

normfilter:{[f]
  / a configured filter -> a list of constraints. A filter qsp cannot make sense of is an error,
  / never "no restriction"
  if[0=count f;:()];
  tree.chk[0h=type f;"row filter must be a list of constraints - see qsp.f"];
  / a single constraint
  if[tree.isfn first f;:enlist f];
  tree.chk[all {(0h=type x)&1<count x} each f;"row filter must be a list of constraints - see qsp.f"];
  :f;
  };

cutoff:{[p;t;c;span]
  / the cutoff for "at least span old" in the column's own type. The cast is not cosmetic:
  / comparing a time-of-day column with a timestamp does not error, it quietly selects the wrong
  / rows
  tree.chk[c in columnsof[p;t];"aged filter on ",string[c],", which is not a column of ",string t];
  ty:first exec typ from p[`schema] where tbl=t,col=c;
  tree.chk[not ty=" ";"aged filter needs the type of ",string[c]," - register ",string[t]," from its meta"];
  tree.chk[ty in temporal;"aged filter needs a temporal column - ",string[c]," is type \"",ty,"\""];
  :ty$now[p]-span;
  };

now:{[p]
  / the policy clock
  n:p[`config;`clock][];
  tree.chk[-12h=type n;"the policy clock must return a timestamp"];
  :n;
  };

/ a marker beside another symbol collapses into a symbol vector
resolvesyms:{[p;u;t;x]
  if[not any x in (tree.agedmark;tree.usermark;tree.nowmark);:x];
  tree.chk[not tree.agedmark in x;"malformed aged filter - build it with qsp.f.aged"];
  :resolve[p;u;t] each x;
  };

resolvesym:{[p;u;x]
  / one symbol: a marker becomes the literal it stands for
  if[x~tree.usermark;:enlist u];
  if[x~tree.nowmark;:now p];
  :x;
  };

/ a marker in literal data: the value it stands for, never enlisted. Inside a symbol list the user
/ stays a symbol, so the list stays one
resolvedata:{[p;u;x]
  if[-11h=type x;:$[x~tree.usermark;u;x~tree.nowmark;now p;x]];
  if[11h=type x;:$[tree.nowmark in x;.z.s[p;u] each x;@[x;where x=tree.usermark;:;u]]];
  if[0h=type x;:.z.s[p;u] each x];
  :x;
  };

resolve:{[p;u;t;x]
  / replace every marker in a constraint with the literal it stands for. A one-item list is
  / quoted data - parse's form for a constant, as qsp.f.eq[c;qsp.USER] and
  / qsp.f.isin[c;(qsp.USER;`shared)] write it - and a marker in it is a value. Anywhere else it
  / is a name, the argument of a call such as `deskof`qsp.user, and becomes a quoted value
  if[(1=count x)and(type x) in 0 11h;:enlist resolvedata[p;u;first x]];
  if[11h=type x;:resolvesyms[p;u;t;x]];
  if[-11h=type x;:resolvesym[p;u;x]];
  if[0h<>type x;:x];
  if[(3=count x)and tree.agedmark~first x;:cutoff[p;t;x 1;x 2]];
  :.z.s[p;u;t] each x;
  };

andtree:{[l] :$[1=count l;first l;{((&);x;y)} over l];};
ortree:{[l] :$[1=count l;first l;{((|);x;y)} over l];};

/ a grant's rows for user u: a lambda is called with the user. A static grant of () is every row,
/ written by whoever made the grant. A lambda's empty result is not: a lookup that does not know
/ the user returns nothing, and that must not open the table. So a lambda says "every row"
/ explicitly, by returning qsp.ALL, and an empty result refuses the query
rowsfor:{[u;r]
  if[not 100h=type r;:r];
  f:r u;
  if[f~allcols;:()];
  tree.chk[0<count f;"row filter function returned no constraints for ",string[u],
    " - return qsp.ALL for every row, or a constraint that matches none"];
  :f;
  };

rawfilter:{[p;u;t]
  / the row filter for a user on a table: () for none, else a constraint list. A lambda that
  / signals, or returns something that is not a constraint list, refuses the query rather than
  / falling back to no filter. The markers are left in, for showing a filter to a person: a
  / marker resolved to a timestamp differs every time it is resolved
  if[0=count g:grantsfor[p;u;t];:()];
  f:normfilter each rowsfor[u] each g`rows;
  / one unrestricted grant wins
  if[any 0=count each f;:()];
  :$[1=count f;first f;enlist ortree andtree each f];
  };
filterfor:{[p;u;t] :resolve[p;u;t] each rawfilter[p;u;t];};

export:([allcols;defaultconfig;new;known;table;partition;refresh;droptable;columnsof;info;
  grant;revoke;member;unmember;allowfunction;denyfunction;allowcall;
  allowjoincall;denycall;gateway;configure;entitiesfor;grantsfor;columnsfor;
  rawfilter;filterfor]);
