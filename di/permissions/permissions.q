/ di.permissions - client access control, ported from TorQ's .pm (code/handlers/permissions.q).
/ Users are placed in groups (which control variable access) and given roles (which control
/ function execution); virtual tables enforce a where clause on a real table. The module owns the
/ `exec` phase of the message handlers, so it decides whether a request is evaluated at all.
/ ---
/ The admin api and the query entry points are EXPORTED, so the rule files that populate the schema
/ reach them through `use` rather than through a root namespace. Only the four names
/ di.torq.proc.gateway reads by symbol are published at root: `.pm.allowed`, `.pm.execas`,
/ `.pm.val` and `.pm.valp`. TorQ's own permissions files therefore need their `.pm.x[...]` calls
/ rewritten as `pm[`x][...]`; see permissions.md.
/ ---
/ Behaviour matches TorQ, including one known weakness documented in permissions.md: the lambda
/ path (lamq) only rejects variable names its own introspection returns, so a name it cannot see
/ is permitted rather than refused.

/ config coercion - a .toml tier gives strings, a .q tier gives typed values
asbool:{[x] $[-1h=type x;x;10h=abs type x;first "B"$(),x;-7h=type x;0<>x;0b]};
aslong:{[x] $[-7h=type x;x;10h=abs type x;"J"$(),x;"j"$x]};

/ wildcard/superuser marker for functions and data
ALL:`$"*";

err:(enlist `)!enlist (::);
err[`func]:{"pm: user role does not permit running function [",string[x],"]"};
err[`selt]:{"pm: no read permission on [",string[x],"]"};
err[`selx]:{"pm: unsupported select statement, superuser only"};
err[`updt]:{"pm: no write permission on [",string[x],"]"};
err[`expr]:{"pm: unsupported expression, superuser only"};
err[`quer]:{"pm: free text queries not permissioned for this user"};
err[`size]:{"pm: returned value exceeds maximum permitted size"};

/ schema - the nine control tables
user:([id:`symbol$()]authtype:`symbol$();hashtype:`symbol$();password:());
groupinfo:([name:`symbol$()]description:());
roleinfo:([name:`symbol$()]description:());
usergroup:([]user:`symbol$();groupname:`symbol$());
userrole:([]user:`symbol$();role:`symbol$());
functiongroup:([]function:`symbol$();fgroup:`symbol$());
access:([]object:`symbol$();entity:`symbol$();level:`symbol$());
function:([]object:`symbol$();role:`symbol$();paramcheck:());
virtualtable:([name:`symbol$()]table:`symbol$();whereclause:());
publictrack:([name:`symbol$()]handle:`int$());

/ admin api - called by the permissions rule files through the root `.pm.*` names
adduser:{[u;a;h;p]
  if[u in key groupinfo;'"pm: cannot add user with same name as existing group"];
  user,:(u;a;h;p);
  };

removeuser:{[u] .z.m.user:.[user;();_;u]};

addgroup:{[n;d]
  if[n in key user;'"pm: cannot add group with same name as existing user"];
  groupinfo,:(n;d);
  };

removegroup:{[n] .z.m.groupinfo:.[groupinfo;();_;n]};

addrole:{[n;d] roleinfo,:(n;d)};

removerole:{[n] .z.m.roleinfo:.[roleinfo;();_;n]};

addtogroup:{[u;g]
  if[not g in key groupinfo;'"pm: no such group, .pm.addgroup first"];
  if[not (u;g) in usergroup;usergroup,:(u;g)];
  };

removefromgroup:{[u;g] if[(u;g) in usergroup;.z.m.usergroup:.[usergroup;();_;usergroup?(u;g)]]};

assignrole:{[u;r]
  if[not r in key roleinfo;'"pm: no such role, .pm.addrole first"];
  if[not (u;r) in userrole;userrole,:(u;r)];
  };

unassignrole:{[u;r] if[(u;r) in userrole;.z.m.userrole:.[userrole;();_;userrole?(u;r)]]};

addfunction:{[f;g] if[not (f;g) in functiongroup;functiongroup,:(f;g)];};

removefunction:{[f;g] if[(f;g) in functiongroup;.z.m.functiongroup:.[functiongroup;();_;functiongroup?(f;g)]]};

grantaccess:{[o;e;l] if[not (o;e;l) in access;access,:(o;e;l)]};

revokeaccess:{[o;e;l] if[(o;e;l) in access;.z.m.access:.[access;();_;access?(o;e;l)]]};

grantfunction:{[o;r;p] if[not (o;r;p) in function;function,:(o;r;p)]};

revokefunction:{[o;r] if[(o;r) in t:`object`role#function;.z.m.function:.[function;();_;t?(o;r)]]};

createvirtualtable:{[n;t;w] if[not n in key virtualtable;virtualtable,:(n;t;w)]};

removevirtualtable:{[n] if[n in key virtualtable;.z.m.virtualtable:.[virtualtable;();_;n]]};

addpublic:{[u;h] .z.m.publictrack:publictrack upsert (u;h)};

removepublic:{[u] .z.m.publictrack:.[publictrack;();_;u]};

cloneuser:{[u;unew;p]
  adduser[unew;ul[0];ul[1];value (string (ul:raze exec authtype,hashtype from user where id=u)[1])," string `",p];
  addtogroup[unew;` sv value(1!usergroup)[u]];
  assignrole[unew;` sv value(1!userrole)[u]];
  };

/ a dictionary of the parameters and the argument values
pdict:{[f;a]
  d:enlist[`]!enlist[::];
  d:d,$[not ca:count a; ();
        f~`select; ();
        (1=count a) and (99h=type first a); first a;
        / a projection carries the function and its fixed parameters. Build the full argument
        / list with :: in the positions still to fill, then drop the supplied args into those -
        / taking fnfp[1] alone loses every fixed parameter after the first (TorQ b03e4753)
        104h=type value f;
          [fnfp:value value f;
           params:value[fnfp 0][1];
           pargs:1_ fnfp;
           allargs:(count params)#enlist[::];
           allargs[til count pargs]:pargs;
           allargs[where 101h=type each allargs]:a;
           params!allargs];
        101h<>type fp:value[value[f]][1]; fp!a;
        ((),(`$string til ca))!a
       ];
  d
  };

/ may this user run this function with these arguments
fchk:{[u;f;a]
  r:exec role from userrole where user=u;
  o:ALL,f,exec fgroup from functiongroup where function=f;
  c:exec paramcheck from function where (object in o) and (role in r);
  k:@[;pdict[f;a];::] each c;
  / an error or a non-boolean paramcheck result counts as a refusal
  k:`boolean$@[k;where not -1h=type each k;:;0b];
  max k
  };

/ may this user read or write this object
achk:{[u;t;rw;pr]
  if[fchk[u;ALL;()]; :1b];
  if[pr and not t in key 1!access; :1b];
  t:ALL,t;
  / a group can contain a group, so chase the whole chain
  g:raze over (exec groupname by user from usergroup)\[u];
  exec 0<count i from access where object in t, entity in g, level in (`read`write!(`read`write;`write))[rw]
  };

/ expression identification
xdq:{first[x] in .q};
isq:{(first[x] in (?;!)) and (count[x]>=5)};

query:{[u;q;b;pr]
  / free-form queries need `select` access
  if[not fchk[u;`select;()]; $[b;'err[`quer][]; :0b]];
  / update or delete in place
  if[((!)~q[0])and(11h=type q[1]);
    if[not achk[u;first q[1];`write;pr]; $[b;'err[`updt][first q 1]; :0b]];
    $[b; :qexe q; :1b];
  ];
  / nested query
  if[isq q 1; $[b; :qexe @[q;1;.z.s[u;;b;pr]]; :1b]];
  / select on a named table
  if[11h=abs type q 1;
    t:first q 1;
    if[t in key virtualtable;
      vt:virtualtable[t];
      q:@[q;1;:;vt`table];
      q:@[q;2;:;enlist first[q 2],vt`whereclause];
    ];
    if[not achk[u;t;`read;pr]; $[b; 'err[`selt][t]; :0b]];
    $[b; :qexe q; :1b];
  ];
  / anything else needs superuser
  if[not fchk[u;ALL;()]; $[b; 'err[`selx][]; :0b]];
  $[b; :qexe q; :1b]
  };

/ .q keyword handlers, keyed by keyword - the null key is the default
dotqd:(enlist `)!enlist {[u;e;b;pr] if[not (fchk[u;ALL;()] or fchk[u;`$string(first e);()]);$[b;'err[`expr][]];:0b]; $[b;qexe e;1b]};
dotqd[`lj`ij`pj`uj]:{[u;e;b;pr] $[b;.z.m.val @[e;1 2;.z.m.expr[u]];1b]};
dotqd[`aj`ej]:{[u;e;b;pr] $[b;.z.m.val @[e;2 3;.z.m.expr[u]];1b]};
dotqd[`wj`wj1]:{[u;e;b;pr] $[b;.z.m.val @[e;2;.z.m.expr[u]];1b]};

dotqf:{[u;q;b;pr]
  qf:.q?(q[0]);
  p:$[null p:dotqd qf;dotqd`;p];
  p[u;q;b;pr]
  };

/ flatten an arbitrary data structure, keeping strings whole
flatten:{raze $[10h=type x;enlist enlist x;1=count x;x;.z.s'[x]]};

/ string the non-strings, leave strings alone
str:{$[10h=type x;;string]x}';

/ root namespaces and their variable names - TorQ reads these from .api.allns/.api.varnames,
/ which di.api does not port (module code does not live in scannable root namespaces)
allns:{[] `$(enlist enlist "."),".",/:string key `};
varnames:{[ns] `$$[ns in `.`.q;"";(string ns),"."],/:string system "v ",string ns};
rootvars:{[] raze varnames each allns[]};

lamq:{[u;e;b;pr]
  rt:rootvars[];
  / public tables are always readable
  rt:rt except distinct exec object from access where entity=`public;
  / tokenize the flattened expression to find possible variable references. Trapped: the string is
  / q's display form of the expression, which elides a long function body and can leave the
  / brackets unbalanced, so -4! signals on it - see permissions.md
  pq:`$distinct @[-4!;raze(str flatten e),'" ";()];
  rqt:rt inter pq;
  prohibited:rqt where not achk[u;;`read;pr] each rqt;
  if[count prohibited;'" | " sv err[`selt] each prohibited];
  $[b; :exe e; :1b]
  };

exe:{v:$[(104<>a)&100<a:abs type first x;.z.m.val;.z.m.valp]x;
  if[.z.m.maxsize<-22!v; 'err[`size][]];
  v
  };

qexe:{v:.z.m.val x; if[.z.m.maxsize<-22!v; 'err[`size][]]; v};

/ is the argument a symbol naming a variable (not a function)
isvar:{$[-11h<>type x;0b;100h>type @[get;x;{[x;y]'err[`selt][x]}[x]]]};

mainexpr:{[u;e;b;pr]
  ie:e;
  e:$[10=type e;parse e;e];
  / variable reference
  if[isvar f:first e;
    if[not achk[u;f;`read;pr]; $[b;'err[`selt][f]; :0b]];
    :$[b;qexe $[f in key virtualtable;exec (?;table;enlist whereclause;0b;()) from virtualtable[f];e];1b];
  ];
  / named function call
  if[-11h=type f;
    / (),e so a bare name (an atom, not a call) drops to an empty argument list rather than signalling
    if[not fchk[u;f;1_ (),e]; $[b;'err[`func][f]; :0b]];
    $[b; :exe ie; :1b];
  ];
  / select / update / delete
  if[isq e; :query[u;e;b;pr]];
  / .q keywords
  if[xdq e; :dotqf[u;e;b;pr]];
  / lambdas - value any dict args before razing
  if[any (100 104h)in type each raze @[e;where 99h=type'[e];value]; :lamq[u;ie;b;pr]];
  / no specific handling - superuser only
  if[not (fchk[u;ALL;()] or fchk[u;`$string(first e);()]); $[b;'err[`expr][f]; :0b]];
  $[b; exe ie; 1b]
  };

parsequery:{[q] q:$[10=type q;q;10h=abs type f:first q;destringf[f],1_ q;q]};

destringf:{$[(s:`$x)in key`.q;.q s;s~`insert;insert;any (100h; 104h)=type first f: @[parse; x; 0];f;s]};

/ check only, never evaluates. A stable name delegating to the projection init builds, so that
/ export (which resolves names at load) and the published root name both stay valid.
allowed:{[u;q] .z.m.allowedfn[u;q]};

/ would this query be permitted - the check without the evaluation
cando:{[u;q] q:parsequery[q]; $[.z.m.enabled;allowed[u;q];1b]};

/ check and run a query as a named user
requ:{[u;q] q:parsequery[q]; $[.z.m.enabled; .z.m.expr[u;q]; .z.m.valp q]};

/ the message-handler entry point - a local call (handle 0) is not checked, as in TorQ
req:{$[.z.w=0; value x; requ[.z.u;x]]};

/ run a query as another user, for a gateway passing the original user to a backend
execas:{[f;u] requ[u;f]};

/ authentication methods - one entry per authtype
auth:(enlist `)!enlist (::);
auth[`local]:{[u;p]
  ud:user[u];
  $[`md5~ht:ud`hashtype;md5[p]~ud`password;0b]
  };
auth[`ldap]:{[u;p]
  / ldap support is not a di module; use it only if the legacy .ldap code is loaded
  $[@[value;`.ldap.enabled;0b];.ldap.login[u;p];0b]
  };

/ the .z.pw entry point
login:{[u;p]
  if[(not u in key user) or (`public=(1!usergroup)[u][`groupname]);
    if[.z.m.public;
      if[""~p;
        adduser[u;`local;`md5;(md5 p)];
        assignrole[u;`publicuser];
        addtogroup[u;`public];
        addpublic[u;.z.w];
        :1b;
      ]];
    :0b;
  ];
  ud:user[u];
  if[not ud[`authtype] in key auth;:0b];
  auth[ud`authtype][u;p]
  };

/ drop public users when their connection closes
droppublic:{[w]
  if[.z.m.public;
    if[0<count publictrack?w;
      u:(value publictrack?w)[0];
      removeuser[u];
      unassignrole[u;`publicuser];
      removefromgroup[u;`public];
      removepublic[u];
    ]];
  };

/ the console entry point - an empty line is not permission checked
consoleinput:{[x] $[x in (1#"\n";"");.Q.s value x;.Q.s $[.z.w=0;value;req]@x]};

getapimeta:{[]
  / the admin api, as TorQ's apidetails.q registers it. names are bare, as di.torq.servers'
  / getapimeta does - di.torq qualifies them when it registers them with di.api
  :flip `name`public`descrip`params`return!flip(
    (`adduser;           1b; "add a user, their authentication type, hash type and hashed password"; "[symbol: username; symbol: authtype; symbol: hashtype; string: hashed password]"; "null");
    (`addgroup;          1b; "add a group, which controls access to tables and variables";           "[symbol: group name; string: description]";                                      "null");
    (`addrole;           1b; "add a role, which controls function execution";                        "[symbol: role name; string: description]";                                       "null");
    (`addtogroup;        1b; "add a user to a group, granting its variable access";                  "[symbol: username; symbol: group name]";                                         "null");
    (`assignrole;        1b; "assign a role to a user, granting its function access";                "[symbol: username; symbol: role name]";                                          "null");
    (`grantaccess;       1b; "give a group read or write access to a variable";                      "[symbol: object; symbol: group; symbol: level (read|write)]";                     "null");
    (`grantfunction;     1b; "give a role access to a function, with a parameter check";             "[symbol: object; symbol: role; function: paramcheck returning a boolean]";       "null");
    (`createvirtualtable;1b; "create a virtual table enforcing a where clause on a real table";      "[symbol: virtual name; symbol: real table; parse tree: where clause]";           "null");
    (`cloneuser;         1b; "add a user with the groups and roles of an existing user";              "[symbol: existing username; symbol: new username; symbol: new password]";        "null"));
  };

/ the only root names this module needs: the four di.torq.proc.gateway reads by symbol. The admin
/ api and the other entry points are reached through the module's export, not through a root
/ namespace. Published whether or not permissions are enabled, because the gateway tests for
/ these names and TorQ's \d .pm defines them unconditionally.
/ `execas` is the one a peer invokes remotely - the gateway rewrites a query to
/ (`.pm.execas;query;user) and sends it to a backend, which re-checks it as the original user.
publishroot:{[]
  set[`.pm.allowed;allowed];
  set[`.pm.execas;execas];
  set[`.pm.val;.z.m.val];
  set[`.pm.valp;.z.m.valp];
  };

registered:0b;

init:{[config;deps]
  if[99h<>type deps;'"di.permissions: deps must be a dict with `log and `handlers keys"];
  if[not `log in key deps;'"di.permissions: log dependency is required - see di.util.log"];
  if[not all `info`warn`error in key deps`log;'"di.permissions: log dict must have `info`warn`error keys"];
  if[not `handlers in key deps;'"di.permissions: handlers dependency is required - injected by di.torq, see di.torq.handlers"];
  .z.m.log:deps`log;
  opt:{[config;k;dflt] $[k in key config;config k;dflt]}[config];
  .z.m.enabled:asbool opt[`enabled;0b];
  .z.m.maxsize:aslong opt[`maxsize;200000000];
  .z.m.runmode:asbool opt[`runmode;1b];
  .z.m.permissivemode:asbool opt[`permissivemode;0b];
  .z.m.public:asbool opt[`public;0b];
  / readonly swaps eval for reval, as TorQ's writeaccess.q does for the whole process
  ro:asbool opt[`readonly;0b];
  .z.m.val:$[ro;reval;eval];
  .z.m.valp:$[ro;{reval parse x};value];
  / runmode baked in: 1b checks and evaluates, 0b returns the boolean only
  .z.m.expr:mainexpr[;;.z.m.runmode;.z.m.permissivemode];
  .z.m.allowedfn:mainexpr[;;0b;0b];
  publishroot[];
  if[not .z.m.enabled;
    .z.m.log[`info][`permissions;"permissions are disabled - no handlers registered"];
    :();
  ];
  if[.z.m.registered;
    .z.m.log[`info][`permissions;"handlers already registered in this process - not re-registering"];
    :();
  ];
  r:deps[`handlers]`register;
  / exec owner of every message handler: the module decides whether the request runs at all
  r[`.z.pg;`exec;`permissions;0j;req];
  r[`.z.ps;`exec;`permissions;0j;req];
  r[`.z.pi;`exec;`permissions;0j;consoleinput];
  r[`.z.pp;`exec;`permissions;0j;{[x] '"pm: HTTP POST requests not permitted"}];
  r[`.z.ws;`exec;`permissions;0j;{[x] '"pm: websocket access not permitted"}];
  r[`.z.pw;`exec;`permissions;0j;login];
  r[`.z.pc;`;`permissions;0j;{[result;w] droppublic w; result}];
  / .z.ph evaluates through .h.val from KDB+ 3.5, so HTTP GET is permission checked, not refused
  set[`.h.val;req];
  .z.m.registered:1b;
  .z.m.log[`info][`permissions;"permissions enabled, maxsize=",(string .z.m.maxsize),", runmode=",(string .z.m.runmode),", permissivemode=",string .z.m.permissivemode];
  };
