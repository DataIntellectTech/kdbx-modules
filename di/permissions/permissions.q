/ role-based access control and authentication. ported from TorQ's permissions.q, writeaccess.q,
/ ldap.q and common/execas.q - see permissions.md for scope, omissions and migration notes.
/ the version lives in the VERSION file and is read by init.q

/ constants (load-time)

/ grants against this mean "any function" / "any table", i.e. superuser. republished as .pm.ALL
wildcard:`$"*";

/ the admin functions a legacy grant file calls at root - publishroot exposes exactly these
grantscriptnames:`adduser`addgroup`addrole`addtogroup`assignrole`grantaccess`grantfunction;

/ the engines this module knows about; only rbac is implemented in v1
knownengines:`rbac`tiered;

/ rejection messages, keyed by reason. no prefix - raiseerror composes one
err:(`symbol$())!();
err[`func]:{"user role does not permit running function [",string[x],"]"};
err[`selt]:{"no read permission on [",string[x],"]"};
err[`selx]:{"unsupported select statement, superuser only"};
err[`updt]:{"no write permission on [",string[x],"]"};
err[`expr]:{"unsupported expression, superuser only"};
err[`quer]:{"free text queries not permissioned for this user"};
err[`size]:{"returned value exceeds maximum permitted size"};

/ schema (load-time templates - the live copies are .z.m.*, populated in init)

userschema:([id:`symbol$()]authtype:`symbol$();hashtype:`symbol$();password:());
groupinfoschema:([name:`symbol$()]description:());
roleinfoschema:([name:`symbol$()]description:());
usergroupschema:([]user:`symbol$();groupname:`symbol$());
userroleschema:([]user:`symbol$();role:`symbol$());
functiongroupschema:([]function:`symbol$();fgroup:`symbol$());
accessschema:([]object:`symbol$();entity:`symbol$();level:`symbol$());
functionschema:([]object:`symbol$();role:`symbol$();paramcheck:());
virtualtableschema:([name:`symbol$()]table:`symbol$();whereclause:());
publictrackschema:([name:`symbol$()]handle:`int$());

/ ldap login-attempt cache. TorQ's server/port columns are dropped - write-only, and fed by a
/ write that throws (it reads .ldap.server, which ldap.q never defines)
ldapcacheschema:([user:`symbol$()]pass:();time:`timestamp$();
  attempts:`long$();success:`boolean$();blocked:`boolean$());

/ config defaults

/ every accepted key with its default; init warns on anything else. keys are uniquely named to
/ survive di.config's flat cascade. see permissions.md for what each one does.
/ NB ignorelist is a MIXED list (symbols and strings) - zpsignore.q matches an async message head
/ against both forms - so it cannot be a typed symbol vector
configdefaults:`enabled`engine`maxsize`runmode`permissivemode`readonly`public`ignorelist`grantdirs`proctype`procname`publishroot!
  (0b;`rbac;200000000;1b;0b;0b;0b;();();`;`;1b);

/ ldap settings; ldapenabled defaults OFF so the suite runs with no native library present.
/ every ldap setting is read from .z.m.config at call time, including by the default ldapbuilddn
ldapconfigdefaults:`ldapenabled`ldaplibpath`ldapdebug`ldapservers`ldapversion`ldapblocktime`ldapchecklimit`ldapchecktime`ldapbuilddnsuf`ldapbuilddn!
  (0b;"";0b;enlist `$"ldap://localhost:0";3;0D00:30:00;3;0D00:05;"";{"uid=",string[x],",",.z.m.config`ldapbuilddnsuf});

/ internal helpers

requiresym:{[ctx;nm;x]
  / validate a public-api argument that must be a symbol
  if[-11h<>type x;
    raiseerror[ctx;nm," must be a symbol, got ",.Q.s1 type x]];
  };

requirestring:{[ctx;nm;x]
  / validate a public-api argument that must be a string (char vector)
  if[10h<>type x;
    raiseerror[ctx;nm," must be a string, got ",.Q.s1 type x]];
  };

normdescription:{[ctx;x]
  / normalise a description to a char VECTOR - load-bearing, not cosmetic. description:() is a
  / general column and q collapses one to a typed vector once it holds only atoms; a 1-char
  / description is a char ATOM, so it would collapse the column and the next longer one throws 'type
  if[-10h=type x;:enlist x];
  if[10h<>type x;
    raiseerror[ctx;"description must be a string, got ",.Q.s1 type x]];
  :x;
  };

requireint:{[ctx;nm;x]
  / validate a public-api argument that must be an integer handle
  if[not type[x] in -6 -7h;
    raiseerror[ctx;nm," must be an integer, got ",.Q.s1 type x]];
  };

requirequery:{[ctx;q]
  / a query must be a string or a parse tree - not an atom, and not a bare symbol
  if[type[q] within -19 -1h;
    raiseerror[ctx;"query must be a string or a parse tree, got an atom of type ",.Q.s1 type q]];
  };

raiseerror:{[ctx;msg]
  / log an error under ctx then signal it, so a failure is observable in the log and not only as a throw
  .z.m.logerr[ctx;msg];
  '"di.permissions: ",string[ctx],": ",msg;
  };

initialised:{[]
  / has init run? a direct (module-rewritten) reference detects prior setup without touching root
  :@[{.z.m.enabled;1b};::;0b];
  };

requireinit:{[ctx]
  / every exported function except init depends on init having wired the logger and the tables
  if[not initialised[];
    '"di.permissions: ",string[ctx],": init must be called before any other function"];
  };

/ init

/ the keys of the single init dict that are dependencies rather than config - everything else in
/ that dict is a config setting. no config key shares a name with one of these
depkeys:`log`handlers`ldapbind;

validatedeps:{[deps]
  / log and handlers are both required and never defaulted - there is no fallback logger
  if[99h<>type deps;
    '"di.permissions: deps must be a dict with `log and `handlers keys - see di.log, di.handlers"];
  if[not all `log`handlers in key deps;
    '"di.permissions: log and handlers dependencies are required; pass `log (`info`warn`error) ",
      "and `handlers (`register`remove) - see di.log, di.handlers; got: ",(", " sv string key deps)];
  if[99h<>type deps`log;
    '"di.permissions: log value must be a dict; pass `info`warn`error functions - see di.log"];
  if[not all `info`warn`error in key deps`log;
    '"di.permissions: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  if[99h<>type deps`handlers;
    '"di.permissions: handlers value must be a dict; pass `register`remove functions - see di.handlers"];
  / only register/remove are required - this module calls no others. unrelated to di.depcheck's
  / handlers contract, which checks the PROVIDER's export dict, not a consumer's deps dict
  if[not all `register`remove in key deps`handlers;
    '"di.permissions: handlers dict must have `register`remove keys; got: ",(", " sv string key deps`handlers)];
  / ldapbind is OPTIONAL - when supplied it replaces the native bind entirely (see ldap.bind)
  if[`ldapbind in key deps;
    if[not type[deps`ldapbind] within 100 112h;
      '"di.permissions: ldapbind must be a function taking (session;dict) and returning a dict with a `ReturnCode key"]];
  };

resolveconfig:{[deps]
  / take the config half of the single init dict and merge it over the known-key defaults, warning
  / about anything unrecognised rather than dropping it silently. depkeys are dependencies, not
  / config, so they are dropped before the unknown-key check and never reach .z.m.config
  defaults:configdefaults,ldapconfigdefaults;
  config:(key[deps] except depkeys)#deps;
  if[count unknown:(key config) except key defaults;
    .z.m.logwarn[`init;"ignoring unrecognised config key(s): ",", " sv string unknown]];
  :defaults,(key[defaults] inter key config)#config;
  };

/ expected value shapes, grouped by check. engine, ignorelist and grantdirs are deliberately
/ absent - engine gets a better message from validateengine, the other two are normalised
boolconfigkeys:`enabled`readonly`permissivemode`runmode`public`ldapenabled`publishroot`ldapdebug;
intconfigkeys:`maxsize`ldapversion`ldapchecklimit;
symconfigkeys:`proctype`procname;
strconfigkeys:`ldaplibpath`ldapbuilddnsuf;
spanconfigkeys:`ldapblocktime`ldapchecktime;

validateconfig:{[cfg]
  / type-check every setting whose shape is fixed, reporting all offenders of a kind at once
  / NB the parameter is `ks`, NOT `keys` - a `keys` parameter throws 'nyi at CALL time, and
  / (`keys in .Q.res) is 0b, so .Q.res will not warn you
  chk:{[cfg;ks;ok;what]
    bad:ks where not ok each cfg ks;
    if[count bad;
      raiseerror[`init;"config key(s) ",(", " sv string bad)," must be ",what]];
    };
  chk[cfg;boolconfigkeys;{-1h=type x};"a boolean (1b or 0b)"];
  chk[cfg;intconfigkeys;{type[x] in -6 -7h};"an integer"];
  chk[cfg;symconfigkeys;{-11h=type x};"a symbol"];
  chk[cfg;strconfigkeys;{10h=type x};"a string"];
  chk[cfg;spanconfigkeys;{-16h=type x};"a timespan (e.g. 0D00:30:00)"];
  chk[cfg;enlist`ldapbuilddn;{type[x] within 100 112h};"a function taking a username"];
  chk[cfg;enlist`ldapservers;{11h=abs type x};"a symbol or symbol list"];
  };

validateengine:{[eng]
  / v1 implements rbac only; the key ships now so tiered can land without reshaping the schema
  if[not -11h=type eng;
    raiseerror[`init;"engine must be a symbol, one of: ",", " sv string knownengines]];
  if[eng~`tiered;
    raiseerror[`init;"engine `tiered (TorQ controlaccess.q) is not implemented in this version; use `rbac"]];
  if[not eng in knownengines;
    raiseerror[`init;"unknown engine ",string[eng],"; expected one of: ",", " sv string knownengines]];
  };

resettables:{[]
  / install fresh copies of every schema - called on first init only, so a re-init preserves grants
  .z.m.user:userschema;
  .z.m.groupinfo:groupinfoschema;
  .z.m.roleinfo:roleinfoschema;
  .z.m.usergroup:usergroupschema;
  .z.m.userrole:userroleschema;
  .z.m.functiongroup:functiongroupschema;
  .z.m.access:accessschema;
  .z.m.function:functionschema;
  .z.m.virtualtable:virtualtableschema;
  .z.m.publictrack:publictrackschema;
  .z.m.ldapcache:ldapcacheschema;
  / defaulted so an injected bind (which skips the native library) still has a session to pass.
  / ldapready is EXPLICIT - inferring readiness from ldapsession existing would always report ready
  .z.m.ldapsession:0i;
  .z.m.ldapready:0b;
  };

init:{[deps]
  / wire deps, resolve config, and (when enabled) claim the message-handling .z.* events.
  / deps: ONE dict carrying `log and `handlers (required), `ldapbind (optional), and any config
  / settings alongside them - the same call shape every di.* module takes, so di.torq can wire it.
  / e.g. perms.init[(`log`handlers!(logdep;handlersdep)),`enabled`readonly!(1b;1b)]
  / idempotent - a second call reclaims the same registrations and leaves grant data intact
  validatedeps[deps];
  .z.m.loginfo:(deps`log)`info;
  .z.m.logwarn:(deps`log)`warn;
  .z.m.logerr:(deps`log)`error;
  .z.m.register:(deps`handlers)`register;
  .z.m.removehandler:(deps`handlers)`remove;
  cfg:resolveconfig[deps];
  validateconfig[cfg];
  validateengine[cfg`engine];
  if[not initialised[];resettables[]];
  .z.m.config:cfg;
  .z.m.enabled:cfg`enabled;
  .z.m.engine:cfg`engine;
  .z.m.maxsize:cfg`maxsize;
  .z.m.runmode:cfg`runmode;
  .z.m.permissivemode:cfg`permissivemode;
  .z.m.readonly:cfg`readonly;
  .z.m.public:cfg`public;
  .z.m.ignorelist:cfg`ignorelist;
  / set before the disabled bail below, so status[] can report it either way
  .z.m.ldapbind:$[`ldapbind in key deps;deps`ldapbind;(::)];
  if[not .z.m.enabled;
    .z.m.loginfo[`init;"di.permissions loaded but disabled - no handlers registered, nothing published at root"];
    :(::)];
  / resolve the native library FIRST - it is the one step that can fail on external state, so a
  / missing .so leaves the process untouched rather than half-configured. an injected bind skips it
  if[(cfg`ldapenabled) and (::)~.z.m.ldapbind;ldap.initialise[ldap.resolvelibpath[]]];
  / root names next: grant files call .pm.addrole etc. on their first line
  $[cfg`publishroot;publishroot[];
    .z.m.loginfo[`init;"publishroot is 0b - .pm.* not exposed at root; legacy grant files will not load"]];
  / a grant file is arbitrary q and may throw - unwind root publication before rethrowing, so a
  / failed init never leaves .pm.* published with nothing registered
  @[loadpermissions;::;{[e]
    unpublishroot[];
    .z.m.enabled:0b;
    raiseerror[`init;"grant file failed to load, root names unpublished: ",e]}];
  ensurepublicscaffolding[];
  registerhandlers[];
  .z.m.loginfo[`init;"di.permissions initialised - engine ",string[.z.m.engine],", readonly ",("disabled";"enabled").z.m.readonly];
  };

ensurepublicscaffolding:{[]
  / the anonymous path assigns `publicuser and adds to `public, and assignrole/addtogroup REFUSE an
  / undefined name - so without these every anonymous login throws out of .z.pw. created only when
  / ABSENT (a grant file's own definitions win) and EMPTY, so an anonymous user is fail-closed
  if[not .z.m.public;:(::)];
  if[not `publicuser in key .z.m.roleinfo;
    admin.addrole[`publicuser;"anonymous users - created by di.permissions, holds no grants by default"];
    .z.m.loginfo[`init;"public access is enabled and no publicuser role was defined - created an empty one"]];
  if[not `public in key .z.m.groupinfo;
    admin.addgroup[`public;"anonymous users - created by di.permissions, holds no grants by default"];
    .z.m.loginfo[`init;"public access is enabled and no public group was defined - created an empty one"]];
  };

status:{[]
  / a snapshot of what this module is currently enforcing - legacy has no equivalent introspection
  requireinit[`status];
  :`enabled`engine`readonly`permissivemode`runmode`maxsize`public`publishroot`ldapenabled`ldapavailable!
    (.z.m.enabled;.z.m.engine;.z.m.readonly;.z.m.permissivemode;.z.m.runmode;.z.m.maxsize;.z.m.public;
     .z.m.config`publishroot;
     .z.m.config`ldapenabled;$[(::)~.z.m.ldapbind;@[{.z.m.ldapready};::;0b];1b]);
  };

/ admin api - grant data management (the admin.* dotted group)
/ what a legacy grant file calls, and what publishroot exposes at .pm.*. all idempotent
admin.wildcard:wildcard;

admin.adduser:{[u;authtype;hashtype;password]
  / register a user with an authentication method and a hashed password
  requireinit[`adduser];
  requiresym[`adduser;"user id";u];
  requiresym[`adduser;"authtype";authtype];
  requiresym[`adduser;"hashtype";hashtype];
  if[u in key .z.m.groupinfo;raiseerror[`adduser;"cannot add user with same name as existing group: ",string u]];
  .z.m.user:.z.m.user upsert (u;authtype;hashtype;password);
  };

admin.removeuser:{[u]
  requireinit[`removeuser];
  requiresym[`removeuser;"user id";u];
  .z.m.user:.[.z.m.user;();_;u];
  };

admin.addgroup:{[n;d]
  requireinit[`addgroup];
  requiresym[`addgroup;"group name";n];
  d:normdescription[`addgroup;d];
  if[n in key .z.m.user;raiseerror[`addgroup;"cannot add group with same name as existing user: ",string n]];
  .z.m.groupinfo:.z.m.groupinfo upsert (n;d);
  };

admin.removegroup:{[n]
  requireinit[`removegroup];
  requiresym[`removegroup;"group name";n];
  .z.m.groupinfo:.[.z.m.groupinfo;();_;n];
  };

admin.addrole:{[n;d]
  requireinit[`addrole];
  requiresym[`addrole;"role name";n];
  d:normdescription[`addrole;d];
  .z.m.roleinfo:.z.m.roleinfo upsert (n;d);
  };

admin.removerole:{[n]
  requireinit[`removerole];
  requiresym[`removerole;"role name";n];
  .z.m.roleinfo:.[.z.m.roleinfo;();_;n];
  };

admin.addtogroup:{[u;g]
  / add a user to a group, giving them the group's table-level access
  requireinit[`addtogroup];
  requiresym[`addtogroup;"user";u];
  requiresym[`addtogroup;"group name";g];
  if[not g in key .z.m.groupinfo;raiseerror[`addtogroup;"no such group, call admin.addgroup first: ",string g]];
  / NB upsert, not join: `.z.m.x:.z.m.x,(...)` flattens an EMPTY table to a plain list
  if[not (u;g) in .z.m.usergroup;.z.m.usergroup:.z.m.usergroup upsert (u;g)];
  };

admin.removefromgroup:{[u;g]
  requireinit[`removefromgroup];
  requiresym[`removefromgroup;"user";u];
  requiresym[`removefromgroup;"group name";g];
  if[(u;g) in .z.m.usergroup;.z.m.usergroup:.[.z.m.usergroup;();_;.z.m.usergroup?(u;g)]];
  };

admin.assignrole:{[u;r]
  / assign a user a role, giving them the role's function-level access
  requireinit[`assignrole];
  requiresym[`assignrole;"user";u];
  requiresym[`assignrole;"role";r];
  if[not r in key .z.m.roleinfo;raiseerror[`assignrole;"no such role, call admin.addrole first: ",string r]];
  if[not (u;r) in .z.m.userrole;.z.m.userrole:.z.m.userrole upsert (u;r)];
  };

admin.unassignrole:{[u;r]
  requireinit[`unassignrole];
  requiresym[`unassignrole;"user";u];
  requiresym[`unassignrole;"role";r];
  if[(u;r) in .z.m.userrole;.z.m.userrole:.[.z.m.userrole;();_;.z.m.userrole?(u;r)]];
  };

admin.addfunction:{[f;g]
  / put a function into a function group, so a grant against the group covers it
  requireinit[`addfunction];
  requiresym[`addfunction;"function";f];
  requiresym[`addfunction;"function group";g];
  if[not (f;g) in .z.m.functiongroup;.z.m.functiongroup:.z.m.functiongroup upsert (f;g)];
  };

admin.removefunction:{[f;g]
  requireinit[`removefunction];
  requiresym[`removefunction;"function";f];
  requiresym[`removefunction;"function group";g];
  if[(f;g) in .z.m.functiongroup;.z.m.functiongroup:.[.z.m.functiongroup;();_;.z.m.functiongroup?(f;g)]];
  };

admin.grantaccess:{[o;e;l]
  / grant an entity (user or group) read or write access to a table or variable
  requireinit[`grantaccess];
  requiresym[`grantaccess;"object";o];
  requiresym[`grantaccess;"entity";e];
  / NB type-check BEFORE the membership test - ("read" in `read`write) throws a raw 'type
  requiresym[`grantaccess;"level";l];
  if[not l in `read`write;
    raiseerror[`grantaccess;"level must be `read or `write, got ",.Q.s1 l]];
  if[not (o;e;l) in .z.m.access;.z.m.access:.z.m.access upsert (o;e;l)];
  };

admin.revokeaccess:{[o;e;l]
  requireinit[`revokeaccess];
  requiresym[`revokeaccess;"object";o];
  requiresym[`revokeaccess;"entity";e];
  requiresym[`revokeaccess;"level";l];
  if[(o;e;l) in .z.m.access;.z.m.access:.[.z.m.access;();_;.z.m.access?(o;e;l)]];
  };

admin.grantfunction:{[o;r;p]
  / grant a role the right to call a function, gated by paramcheck p.
  / p MUST be a function - a non-boolean paramcheck result is coerced to 0b, so a literal 1b would
  / fail closed rather than grant access
  requireinit[`grantfunction];
  if[not type[p] within 100 112h;raiseerror[`grantfunction;"paramcheck must be a function; a literal fails closed"]];
  if[not (o;r;p) in .z.m.function;.z.m.function:.z.m.function upsert (o;r;p)];
  };

admin.revokefunction:{[o;r]
  requireinit[`revokefunction];
  requiresym[`revokefunction;"object";o];
  requiresym[`revokefunction;"role";r];
  t:`object`role#.z.m.function;
  if[(o;r) in t;.z.m.function:.[.z.m.function;();_;t?(o;r)]];
  };

admin.createvirtualtable:{[n;t;w]
  / expose a named view of a table with an implicit where-clause spliced into any select against it
  requireinit[`createvirtualtable];
  requiresym[`createvirtualtable;"name";n];
  requiresym[`createvirtualtable;"table";t];
  if[not n in key .z.m.virtualtable;.z.m.virtualtable:.z.m.virtualtable upsert (n;t;w)];
  };

admin.removevirtualtable:{[n]
  requireinit[`removevirtualtable];
  requiresym[`removevirtualtable;"name";n];
  if[n in key .z.m.virtualtable;.z.m.virtualtable:.[.z.m.virtualtable;();_;n]];
  };

admin.addpublic:{[u;w]
  / track an auto-provisioned anonymous user against the handle that created it
  requireinit[`addpublic];
  requiresym[`addpublic;"user";u];
  requireint[`addpublic;"handle";w];
  .z.m.publictrack:.z.m.publictrack upsert (u;w);
  };

admin.removepublic:{[u]
  requireinit[`removepublic];
  requiresym[`removepublic;"user";u];
  .z.m.publictrack:.[.z.m.publictrack;();_;u];
  };

admin.cloneuser:{[u;unew;p]
  / copy a user's auth method plus group and role membership onto a new user id
  requireinit[`cloneuser];
  requiresym[`cloneuser;"source user";u];
  requiresym[`cloneuser;"new user id";unew];
  requirestring[`cloneuser;"password";p];
  if[not u in key .z.m.user;raiseerror[`cloneuser;"no such user to clone: ",string u]];
  ul:raze exec authtype,hashtype from .z.m.user where id=u;
  / NB hash directly - TorQ builds and EVALUATES a string here, which throws on a password
  / containing a space or a backtick, and evaluates caller-supplied text in an auth path
  if[not `md5~ul 1;
    raiseerror[`cloneuser;"cannot clone user with unsupported hashtype ",string[ul 1],"; only md5 is supported"]];
  admin.adduser[unew;ul 0;ul 1;md5 p];
  admin.addtogroup[unew;] each exec groupname from .z.m.usergroup where user=u;
  admin.assignrole[unew;] each exec role from .z.m.userrole where user=u;
  };

/ rbac engine - permission checks

rbac.pdict:{[f;a]
  / build a parameter-name -> value dict for a call, so a paramcheck can inspect arguments by name
  / handles bare calls, select, and projections (rebuilding the full argument list from the
  / projection's captured args plus the new ones)
  d:enlist[`]!enlist[::];
  d:d,$[not ca:count a; ();
        f~`select; ();
        (1=count a) and (99h=type first a); first a;
        104h=type value f; [fnfp:value value f; (value[fnfp 0][1])!fnfp[1],a];
        101h<>type fp:value[value[f]][1]; fp!a;
        ((),(`$string til ca))!a
       ];
  :d;
  };

rbac.fchk:{[u;f;a]
  / may user u call function f with args a?
  / any one satisfied paramcheck is sufficient - a wildcard (superuser) grant therefore trumps a
  / failed paramcheck from another role
  r:exec role from .z.m.userrole where user=u;
  o:wildcard,f,exec fgroup from .z.m.functiongroup where function=f;
  c:exec paramcheck from .z.m.function where (object in o),role in r;
  k:@[;rbac.pdict[f;a];::] each c;
  k:`boolean$@[k;where not -1h=type each k;:;0b];
  :max k;
  };

rbac.achk:{[u;t;rw;pr]
  / may user u read/write table t? pr is permissive mode - an object with no grants at all is allowed
  if[rbac.fchk[u;wildcard;()]; :1b];
  if[pr and not t in key 1!.z.m.access; :1b];
  t:wildcard,t;
  / groups can contain groups - chase membership to a fixed point
  g:raze over (exec groupname by user from .z.m.usergroup)\[u];
  :exec 0<count i from .z.m.access where object in t,entity in g,level in (`read`write!(`read`write;`write))rw;
  };

/ rbac engine - expression classification and dispatch

rbac.isq:{[x]
  / is this a select/update/delete-shaped parse tree?
  :(first[x] in (?;!)) and count[x]>=5;
  };

rbac.xdq:{[x]
  / is the head of this expression a .q keyword?
  :first[x] in .q;
  };

rbac.qexe:{[x]
  / evaluate a parse tree and enforce the result-size cap
  v:val x;
  if[.z.m.maxsize<-22!v;raiseerror[`qexe;err[`size][]]];
  :v;
  };

rbac.exe:{[x]
  / evaluate an expression, choosing parse-tree vs string evaluation by the head's type.
  / NB only operator/iterator/composition heads reach val; symbol (11h) and lambda (100h) heads fall
  / through to valp, as does a string - valp handles all three
  v:$[(104<>a)&100<a:abs type first x;val;valp]x;
  if[.z.m.maxsize<-22!v;raiseerror[`exe;err[`size][]]];
  :v;
  };

rbac.symsin:{[x]
  / every symbol appearing anywhere in a parse-tree fragment.
  / NB only general lists (0h) and dicts (99h) recurse - recursing into an atom would not terminate.
  / lamq's stringify-and-tokenise cannot be reused: these trees hold function values and `string` throws
  t:type x;
  :$[-11h=t;enlist x;
     11h=t;x;
     0h=t;raze .z.s each x;
     99h=t;raze .z.s each (key x;value x);
     `$()];
  };

rbac.checkclauses:{[u;q;b;pr]
  / read-check every object named in a select's where, by and columns clauses - the target at q[1] is
  / already checked by the caller, 2_q is the rest. uses rbac.isdefinedvar, the SAME predicate a bare
  / reference and lamq use, minus the target's own column names.
  / full rationale, the leak it closes and the false-positive measurements: permissions.md, "Clause checking"
  / the guard below is defence in depth: rbac.isq gates count>=5 in a DIFFERENT function, and on a short
  / list 2_q silently yields () - nothing checked, query PERMITTED. fail loudly rather than fail open
  if[5>count q;
    raiseerror[`query;"malformed query tree - expected at least 5 elements, got ",string count q]];
  tgt:$[11h=abs type q 1;first q 1;`];
  refs:distinct rbac.symsin 2_q;
  refs:refs except @[{cols get x};tgt;`$()];
  refs:refs where rbac.isdefinedvar each refs;
  / public objects are always readable, as in lamq
  refs:refs except distinct exec object from .z.m.access where entity=`public;
  bad:refs where not rbac.achk[u;;`read;pr] each refs;
  if[count bad;
    $[b;raiseerror[`query;" | " sv err[`selt] each bad];:0b]];
  :1b;
  };

rbac.query:{[u;q;b;pr]
  / permission-check a select/update/delete-shaped query
  / b: execute (1b) vs return a boolean verdict (0b). pr: permissive mode
  if[not rbac.fchk[u;`select;()];$[b;raiseerror[`query;err[`quer][]];:0b]];
  / update or delete in place - needs write access on the target
  if[((!)~q 0) and 11h=type q 1;
    if[not rbac.achk[u;first q 1;`write;pr];$[b;raiseerror[`query;err[`updt][first q 1]];:0b]];
    if[not rbac.checkclauses[u;q;b;pr];:0b];
    :$[b;rbac.qexe q;1b]];
  / nested query - recurse into the inner select
  if[rbac.isq q 1;:$[b;rbac.qexe @[q;1;rbac.expr[u]];1b]];
  / select on a named table, resolving virtual-table indirection first
  if[11h=abs type q 1;
    t:first q 1;
    if[t in key .z.m.virtualtable;
      vt:.z.m.virtualtable t;
      q:@[q;1;:;vt`table];
      q:@[q;2;:;enlist first[q 2],vt`whereclause]];
    if[not rbac.achk[u;t;`read;pr];$[b;raiseerror[`query;err[`selt][t]];:0b]];
    if[not rbac.checkclauses[u;q;b;pr];:0b];
    :$[b;rbac.qexe q;1b]];
  / anything else - superuser only
  if[not rbac.fchk[u;wildcard;()];$[b;raiseerror[`query;err[`selx][]];:0b]];
  :$[b;rbac.qexe q;1b];
  };

/ dispatch table for .q-namespace calls. the join entries substitute a permission-checking
/ evaluator into their table arguments, so nested table references still get checked
rbac.dotqd:enlist[`]!enlist{[u;e;b;pr]
  if[not (rbac.fchk[u;wildcard;()] or rbac.fchk[u;`$string first e;()]);$[b;raiseerror[`dotqf;err[`expr][]];:0b]];
  :$[b;rbac.qexe e;1b];
  };
/ NB the dry-run branch checks the join's table arguments; TorQ returned 1b unconditionally, so
/ `allowed` permitted joins `requ` then refused
rbac.dotqd[`lj`ij`pj`uj]:{[u;e;b;pr] :$[b;val @[e;1 2;rbac.expr[u]];all rbac.mainexpr[u;;0b;pr] each e 1 2]};
rbac.dotqd[`aj`ej]:{[u;e;b;pr] :$[b;val @[e;2 3;rbac.expr[u]];all rbac.mainexpr[u;;0b;pr] each e 2 3]};
rbac.dotqd[`wj`wj1]:{[u;e;b;pr] :$[b;val @[e;2;rbac.expr[u]];rbac.mainexpr[u;e 2;0b;pr]]};

rbac.dotqf:{[u;q;b;pr]
  / route a .q-keyword call to its handler in the dispatch table
  qf:.q?q 0;
  p:$[null p:rbac.dotqd qf;rbac.dotqd`;p];
  :p[u;q;b;pr];
  };

/ rbac engine - lambda expressions

rbac.flatten:{[x]
  / flatten an arbitrary nested structure, keeping strings intact as single units
  :raze $[10h=type x;enlist enlist x;1=count x;x;.z.s'[x]];
  };

rbac.str:{$[10h=type x;;string]x}';

rbac.isdefinedvar:{[s]
  / is this symbol the name of a currently defined non-function variable at root?
  / protected: an undefined name throws, which simply means "not a variable"
  / NB the null-symbol guard is load-bearing: the tokeniser emits ` for whitespace and (get `)
  / returns the ROOT NAMESPACE DICT (99h), which would read as a variable and deny every lambda query
  if[-11h<>type s;:0b];
  if[null s;:0b];
  / a view must be permission-checked, but `get` would EVALUATE it - letting an unpermissioned
  / caller trigger arbitrary computation before any check runs. recognise it by name instead
  if[s in views[];:1b];
  :@[{100h>type get x};s;0b];
  };

rbac.lamq:{[u;e;b;pr]
  / read-check every defined root variable a lambda references, reporting all failures at once.
  / NB tokenises FIRST and tests only those tokens - O(tokens), not TorQ's O(all root names)
  pq:`$distinct -4!raze(rbac.str rbac.flatten e),'" ";
  rqt:pq where rbac.isdefinedvar each pq;
  / public objects are always readable
  rqt:rqt except distinct exec object from .z.m.access where entity=`public;
  prohibited:rqt where not rbac.achk[u;;`read;pr] each rqt;
  / a dry run reports a verdict; only a real execution raises (TorQ raises either way)
  if[count prohibited;
    $[b;raiseerror[`lamq;" | " sv err[`selt] each prohibited];:0b]];
  :$[b;rbac.exe e;1b];
  };

/ rbac engine - top-level classifier

rbac.isvar:{[x]
  / is x a symbol naming an existing non-function variable?
  :$[-11h<>type x;0b;100h>type @[get;x;{[n;e] raiseerror[`isvar;err[`selt] n]}[x]]];
  };

rbac.mainexpr:{[u;e;b;pr]
  / classify an expression and permission-check it accordingly
  ie:e;
  / guard the parse: client input is untrusted, and an unparseable query would otherwise escape as a
  / bare q error (e.g. ' ) - unprefixed, unlogged, and with no audit trail of who sent it
  e:$[10=type e;@[parse;e;{[m] raiseerror[`mainexpr;"could not parse query: ",m]}];e];
  / a bare variable reference - read check, through any virtual-table indirection
  if[rbac.isvar f:first e;
    if[not rbac.achk[u;f;`read;pr];$[b;raiseerror[`mainexpr;err[`selt] f];:0b]];
    :$[b;rbac.qexe $[f in key .z.m.virtualtable;exec (?;table;enlist whereclause;0b;()) from .z.m.virtualtable f;e];1b]];
  / a named function call
  if[-11h=type f;
    if[not rbac.fchk[u;f;1_e];$[b;raiseerror[`mainexpr;err[`func] f];:0b]];
    :$[b;rbac.exe ie;1b]];
  / select / update / delete
  if[rbac.isq e;:rbac.query[u;e;b;pr]];
  / .q keyword call
  if[rbac.xdq e;:rbac.dotqf[u;e;b;pr]];
  / lambda - value any dict args before razing
  if[any (100 104h) in type each raze @[e;where 99h=type'[e];value];:rbac.lamq[u;ie;b;pr]];
  / unrecognised - superuser only
  if[not (rbac.fchk[u;wildcard;()] or rbac.fchk[u;`$string first e;()]);$[b;raiseerror[`mainexpr;err[`expr] f];:0b]];
  :$[b;rbac.exe ie;1b];
  };

/ execute-and-check. reads runmode/permissivemode at CALL time, so both are tunable at runtime
rbac.expr:{[u;e] :rbac.mainexpr[u;e;.z.m.runmode;.z.m.permissivemode]};

/ query normalisation and the public entry points

rbac.destringf:{[x]
  :$[(s:`$x) in key `.q;.q s;s~`insert;insert;any (100h;104h)=type first f:@[parse;x;0];f;s];
  };

rbac.parsequery:{[q]
  / normalise a string or .q-keyword-headed query into its resolved parse tree
  :$[10=type q;q;10h=abs type f:first q;rbac.destringf[f],1_q;q];
  };

val:{[x]
  / evaluate a parse tree, under reval when read-only mode is on. resolved per CALL, not at load
  / time as TorQ does, so read-only is togglable without a restart.
  / NB TESTING: reval does NOT enforce at .z.w=0 (the console), only over a real handle - so a unit
  / test asserting a blocked write FAILS against correct code. enforcement lives in the integration suite
  requireinit[`val];
  :$[.z.m.readonly;reval x;eval x];
  };

valp:{[x]
  / evaluate a string or parse tree, under reval when read-only mode is on.
  / NB parse only a STRING - it throws 'type on a list, and rbac.exe routes parse trees here, which
  / is the standard h(`func;arg) IPC shape
  requireinit[`valp];
  if[not .z.m.readonly;:value x];
  / NB a PARSE TREE must keep `value` semantics (head resolved, arguments NOT). handing it straight
  / to `reval` uses EVAL semantics, which resolve a symbol argument to its variable: (`echo;`secret)
  / would return secret's contents to a caller with no grant on it, since only the head is checked.
  / applying value to the tree as a literal inside reval keeps value's semantics and reval's write ban
  :$[10h=type x;reval parse x;reval (value;enlist x)];
  };

allowed:{[u;q]
  / would user u be permitted to run q? a dry-run verdict - never executes.
  / NB reads the CONFIGURED permissive mode (TorQ pins it off), so allowed and requ agree
  requireinit[`allowed];
  requiresym[`allowed;"user";u];
  requirequery[`allowed;q];
  :rbac.mainexpr[u;rbac.parsequery q;0b;.z.m.permissivemode];
  };

requ:{[u;q]
  / permission-check q as user u and execute it; passes through untouched when disabled
  requireinit[`requ];
  requiresym[`requ;"user";u];
  requirequery[`requ;q];
  q:rbac.parsequery q;
  :$[.z.m.enabled;rbac.expr[u;q];valp q];
  };

execas:{[f;u]
  / run f as user u, subject to that user's permissions
  requireinit[`execas];
  requiresym[`execas;"user";u];
  requirequery[`execas;f];
  :requ[u;f];
  };

/ ldap authentication backend (the ldap.* dotted group)
/ the native library is OPTIONAL - nothing here is touched unless ldapenabled is set

ldap.resolvelibpath:{[]
  / the native library, from the ldaplibpath setting, falling back to $KDBLIB
  p:.z.m.config`ldaplibpath;
  :$[0<count p;`$p;`$getenv[`KDBLIB],"/",string[.z.o],"/kdbldap"];
  };

ldap.debuglog:{[msg]
  / ldap chatter, gated behind ldapdebug and routed to the injected logger
  if[.z.m.config`ldapdebug;.z.m.loginfo[`ldap;msg]];
  };

ldap.initialise:{[libpath]
  / bind the native entry points and open a session. only these four are ever called - TorQ binds
  / eleven, and each binding is a load-time failure point
  libfile:hsym ` sv libpath,`so;
  if[()~key libfile;
    raiseerror[`ldap;"cannot find ldap library file: ",(1_string libfile),"; set ldaplibpath or $KDBLIB, or set ldapenabled:0b"]];
  .z.m.ldapinit:libpath 2:(`kdbldap_init;2);
  .z.m.ldapsetoption:libpath 2:(`kdbldap_set_option;3);
  .z.m.ldapbindnative:libpath 2:(`kdbldap_bind_s;4);
  .z.m.ldaperr2string:libpath 2:(`kdbldap_err2string;1);
  .z.m.ldapsession:0i;
  r:.z.m.ldapinit[.z.m.ldapsession;.z.m.config`ldapservers];
  if[0<>r;raiseerror[`ldap;"error initialising ldap: ",.z.m.ldaperr2string r]];
  s:.z.m.ldapsetoption[.z.m.ldapsession;`LDAP_OPT_PROTOCOL_VERSION;.z.m.config`ldapversion];
  if[0<>s;raiseerror[`ldap;"error setting ldap protocol version: ",.z.m.ldaperr2string s]];
  .z.m.ldapready:1b;
  .z.m.loginfo[`ldap;"ldap initialised against ",", " sv string .z.m.config`ldapservers];
  };

ldap.bind:{[sess;customdict]
  / thin wrapper over the native bind, merging caller overrides onto the default dn/cred/mech dict
  defaultkeys:`dn`cred`mech;
  if[customdict~(::);customdict:()!()];
  if[99h<>type customdict;raiseerror[`ldap;"bind overrides must be (::) or a dictionary"]];
  upddict:(defaultkeys!```),customdict;
  / dispatch through the injected bind when supplied, else the native library. the injected form
  / lets the caching and lockout logic be exercised without a directory server
  r:$[(::)~.z.m.ldapbind;.z.m.ldapbindnative[sess;;;]. upddict defaultkeys;.z.m.ldapbind[sess;upddict]];
  / NB validate the shape: r[`ReturnCode] on an INTEGER is handle apply, so a bind returning 42
  / would attempt an IPC write to file descriptor 42. fail closed instead
  if[99h<>type r;
    raiseerror[`ldap;"bind returned a ",(.Q.s1 type r)," - expected a dictionary with a `ReturnCode key"]];
  if[not `ReturnCode in key r;
    raiseerror[`ldap;"bind returned a dictionary with no `ReturnCode key; got: ",(", " sv string key r)]];
  :r;
  };

ldap.errstring:{[rc]
  / describe a bind return code, falling back to the raw code when no native library is loaded
  :$[(::)~.z.m.ldapbind;.z.m.ldaperr2string rc;"return code ",string rc];
  };

ldap.blocked:{[usr;incache]
  / is this user currently locked out? clears an expired lockout as a side effect
  / a null blocktime means the lockout never expires
  if[not incache`blocked;:0b];
  if[null .z.m.config`ldapblocktime;
    ldap.debuglog["authentication attempts for user ",(string usr)," are blocked"];
    :1b];
  bt:incache[`time]+.z.m.config`ldapblocktime;
  if[.z.p<bt;
    ldap.debuglog["authentication attempts for user ",(string usr)," are blocked until ",string bt];
    :1b];
  .z.m.ldapcache:update attempts:0,blocked:0b from .z.m.ldapcache where user=usr;
  :0b;
  };

ldap.login:{[usr;pass]
  / authenticate a user against the ldap server, with caching and lockout
  requireinit[`ldaplogin];
  if[not .z.m.config`ldapenabled;
    .z.m.logwarn[`ldap;"ldap login attempted but ldapenabled is 0b"];
    :0b];
  incache:.z.m.ldapcache usr;
  dn:(.z.m.config`ldapbuilddn) usr;
  if[ldap.blocked[usr;incache];:0b];
  incache:.z.m.ldapcache usr;
  np:md5 pass;
  / skip the server entirely when the previous attempt succeeded recently with the same password
  authorised:$[all (incache`success;incache[`time]>.z.p-.z.m.config`ldapchecktime;incache[`pass]~np);
    enlist[`ReturnCode]!enlist 0i;
    .[ldap.bind;(.z.m.ldapsession;`dn`cred!(dn;pass));enlist[`ReturnCode]!enlist -2i]];
  ok:authorised[`ReturnCode]~0i;
  .z.m.ldapcache:.z.m.ldapcache upsert (usr;np;.z.p;$[ok;0;1+0^incache`attempts];ok;0b);
  $[ok;
    ldap.debuglog["successfully authenticated user ",dn];
    ldap.debuglog["failed to authenticate user ",dn,": ",ldap.errstring authorised`ReturnCode]];
  if[(.z.m.config`ldapchecklimit)<=.z.m.ldapcache[usr]`attempts;
    .z.m.ldapcache:update blocked:1b from .z.m.ldapcache where user=usr;
    .z.m.logwarn[`ldap;"attempt limit reached, user ",dn," has been locked out"]];
  :ok;
  };

unblock:{[usr]
  / clear a user's ldap lockout - the admin escape hatch
  requireinit[`unblock];
  requiresym[`unblock;"user";usr];
  if[not usr in key .z.m.ldapcache;
    .z.m.loginfo[`unblock;"no ldap login record for user ",string usr];
    :(::)];
  / clear the whole cached state, not only a lockout - clearing `success` means the next login
  / always reaches the server, which is what makes this usable after a password change
  wasblocked:.z.m.ldapcache[usr]`blocked;
  .z.m.ldapcache:update attempts:0,success:0b,blocked:0b from .z.m.ldapcache where user=usr;
  .z.m.loginfo[`unblock;$[wasblocked;"unblocked user ";"cleared cached ldap state for user "],string usr];
  };

/ authentication backends (the auth.* dotted group)
/ one function per authtype, so a user row's authtype selects its backend

auth.local:{[u;p]
  / compare a hashed password against the stored hash. md5 is the only hashtype TorQ supports
  ud:.z.m.user u;
  :$[`md5~ud`hashtype;(md5 p)~ud`password;0b];
  };

auth.ldap:{[u;p]
  / delegate to the ldap backend, which is a no-op returning 0b when ldap is disabled
  :$[.z.m.config`ldapenabled;ldap.login[u;p];0b];
  };

/ connection lifecycle - the bodies di.handlers registers

authenticate:{[u;p]
  / the .z.pw body: authenticate a connecting user, optionally auto-provisioning an anonymous one.
  / anonymous access is gated by the `public` config key, replacing TorQ's -public command-line read
  requireinit[`authenticate];
  / NB FIRST-ROW lookup is deliberate, not a bug. correct by construction - the branch below puts an
  / anonymous user in exactly one group - and a full membership check would be a privilege CHANGE:
  / a real user also in `public would be rejected with a valid password, or have their row upserted
  / over and role demoted. that is an account-takeover path. see permissions.md
  known:u in key .z.m.user;
  ingrouppublic:`public~(1!.z.m.usergroup)[u]`groupname;
  if[(not known) or ingrouppublic;
    if[not .z.m.public;
      .z.m.logwarn[`authenticate;"rejected unknown user ",(string u)," (public access disabled)"];
      :0b];
    if[not ""~p;
      .z.m.logwarn[`authenticate;"rejected anonymous login for ",(string u)," (a password was supplied)"];
      :0b];
    admin.adduser[u;`local;`md5;md5 p];
    admin.assignrole[u;`publicuser];
    admin.addtogroup[u;`public];
    admin.addpublic[u;.z.w];
    .z.m.loginfo[`authenticate;"provisioned anonymous user ",string u];
    :1b];
  ud:.z.m.user u;
  if[not ud[`authtype] in key auth;
    .z.m.logwarn[`authenticate;"rejected ",(string u),": unknown authtype ",string ud`authtype];
    :0b];
  / log both outcomes - a warn-only trail cannot answer "who connected"
  ok:auth[ud`authtype][u;p];
  $[ok;.z.m.loginfo[`authenticate;"authenticated user ",string u];
       .z.m.logwarn[`authenticate;"failed authentication for user ",string u]];
  :ok;
  };

droppublic:{[w]
  / the .z.pc body: tear down an auto-provisioned anonymous user when its connection closes
  requireinit[`droppublic];
  if[not .z.m.public;:(::)];
  tracked:exec name from .z.m.publictrack where handle=w;
  if[0=count tracked;:(::)];
  u:first tracked;
  admin.removeuser[u];
  admin.unassignrole[u;`publicuser];
  admin.removefromgroup[u;`public];
  admin.removepublic[u];
  .z.m.loginfo[`droppublic;"dropped anonymous user ",string u];
  };

/ handler bodies - registered with di.handlers, never exported
/ passed to register BY VALUE, so they need no public name

hooks.sync:{[x]
  / .z.pg exec: permission-check and run a synchronous message
  / handle 0 (the console / this process itself) bypasses checking entirely, as in TorQ
  :$[.z.w=0;value x;requ[.z.u;x]];
  };

hooks.async:{[x]
  / .z.ps exec: as hooks.sync, but first honouring the ignore-list (zpsignore.q, folded inline -
  / di.handlers has no skip-exec path, so the bypass cannot be a phase). .z.ps ONLY, as in TorQ
  if[any first[x]~/:.z.m.ignorelist;:value x];
  :$[.z.w=0;value x;requ[.z.u;x]];
  };

hooks.console:{[x]
  / .z.pi exec: console input. blank lines skip the check; results are console-formatted.
  / console input IS permission-checked - the .z.w=0 bypass in hooks.sync is what keeps it usable
  :$[x in (1#"\n";"");.Q.s value x;.Q.s $[.z.w=0;value x;requ[.z.u;x]]];
  };

hooks.rejectpost:{[x]
  / .z.pp exec: TorQ disables HTTP POST outright when permissions are on - not a check, a refusal
  raiseerror[`http;"HTTP POST requests are not permitted"];
  };

hooks.rejectws:{[x]
  / .z.ws exec: TorQ disables websocket messages outright when permissions are on
  raiseerror[`websocket;"websocket access is not permitted"];
  };

/ event -> exec body. .z.pw is binary, the rest unary; .z.pc is a simple observer, registered separately
execbodies:`.z.pw`.z.pg`.z.ps`.z.pi`.z.pp`.z.ws!
  (authenticate;hooks.sync;hooks.async;hooks.console;hooks.rejectpost;hooks.rejectws);

/ root-name publication
/ `use` mangles module code into a private namespace, so anything an evaluated grant file must
/ reach has to be published at a real root name - legacy files call .pm.addrole etc on line one.
/ published during init but ONLY when enabled, unlike TorQ; safe because gateway.q guards on
/ existence. see permissions.md, "Root-name publication"

publishroot:{[]
  / expose the wildcard constant and the grant-script admin functions at .pm.*
  set[`.pm.ALL;wildcard];
  {[n] set[` sv `.pm,n;admin n]} each grantscriptnames;
  .z.m.loginfo[`publishroot;"published ",(string 1+count grantscriptnames)," names under .pm for legacy grant scripts"];
  };

unpublishroot:{[]
  / remove every name publishroot created, leaving no root residue behind
  present:(key `.pm) inter `ALL,grantscriptnames;
  if[count present;![`.pm;();0b;present]];
  };

/ grant data loading

loadgrantfile:{[path]
  / load one grant file at ROOT (not via `use`) so its .pm.* calls resolve against the published names
  if[()~key hsym `$path;
    .z.m.loginfo[`loadpermissions;"grant file not found, skipping: ",path];
    :(::)];
  .z.m.loginfo[`loadpermissions;"loading grant file ",path];
  system "l ",path;
  };

loadpermissions:{[]
  / load the grant cascade: default -> proctype -> procname, under each configured directory
  requireinit[`loadpermissions];
  / NB normalise: a bare string is ONE directory - (),"path" would make each char a directory
  dirs:.z.m.config`grantdirs;
  dirs:$[10h=type dirs;enlist dirs;(),dirs];
  if[0=count dirs;
    .z.m.loginfo[`loadpermissions;"no grantdirs configured, nothing to load"];
    :(::)];
  names:`default,(.z.m.config`proctype),.z.m.config`procname;
  names:names where not null names;
  / NB nested each, NOT cross - cross joins with `,`, concatenating the path STRING with the
  / symbol instead of pairing them, giving a mixed list that rank-errors on dot-apply
  {[nms;d] {[d;n] loadgrantfile[d,"/",(string n),".q"]}[d;] each nms}[names;] each dirs;
  };

/ registration and teardown

registerhandlers:{[]
  / claim the exec phase of every message-handling event, plus a .z.pc observer for cleanup.
  / a stable name means a re-init reclaims the same events rather than colliding
  {[e] .z.m.register[e;`exec;`di.permissions;0;execbodies e]} each key execbodies;
  / priority 0 - lower runs first, so this cleanup precedes any other observer, matching TorQ's
  / {droppublic[y];@[x;y]} order. TorqX registers gateway bookkeeping at 10, behind this
  .z.m.register[`.z.pc;`;`di.permissions;0;droppublic];
  / .h.val is where HTTP GET permissioning happens on kdb+ 3.5+. not a .z.* event, so di.handlers
  / would reject it - assign directly. .z.ph is NOT claimed: an exec owner there replaces the
  / built-in handler wholesale.
  / NB capture the original ONCE - init is idempotent, so an unguarded capture on a second init
  / would record our own hooks.sync as the "original"
  if[not @[{.z.m.hvaloriginal;1b};::;0b];.z.m.hvaloriginal:@[get;`.h.val;{(::)}]];
  set[`.h.val;hooks.sync];
  .z.m.loginfo[`init;"registered exec on ",(", " sv string key execbodies),", observer on .z.pc, and .h.val"];
  };

teardown:{[]
  / release everything init installed: handler registrations, .h.val, and the published root names
  / leaves grant data intact, so a subsequent init re-registers and re-publishes cleanly
  requireinit[`teardown];
  if[not .z.m.enabled;
    .z.m.loginfo[`teardown;"di.permissions is disabled, nothing to release"];
    :(::)];
  / NB dot-apply, not @ - `@[f;(a;b;c);h]` passes the LIST as one argument, rank-errors into the
  / handler, and every removal silently "succeeds"
  {[e] .[.z.m.removehandler;(e;`exec;`di.permissions);{[e2] .z.m.logwarn[`teardown;"could not remove exec handler: ",e2]}]} each key execbodies;
  .[.z.m.removehandler;(`.z.pc;`;`di.permissions);{[e2] .z.m.logwarn[`teardown;"could not remove .z.pc observer: ",e2]}];
  $[(::)~.z.m.hvaloriginal;@[{![`.h;();0b;enlist`val];};::;{[e2]}];set[`.h.val;.z.m.hvaloriginal]];
  unpublishroot[];
  .z.m.enabled:0b;
  .z.m.loginfo[`teardown;"di.permissions released - handlers, .h.val and .pm.* root names removed"];
  };

/ api metadata

getapimeta:{[]
  / one row per CALLABLE export, for di.torq to register with di.api. init and getapimeta are
  / omitted as plumbing; teardown is a real lifecycle operation and gets a row. names are bare
  :flip `name`public`descrip`params`return!flip(
    (`teardown;        1b; "release handler registrations, .h.val and the published .pm.* root names";
       "[]";                                                        "null");
    (`version;         1b; "module version string";
       "[]";                                                        "string: version");
    (`status;          1b; "what this module is currently enforcing - engine, readonly, ldap state";
       "[]";                                                        "dict: setting -> value");
    (`allowed;         1b; "would this user be permitted to run this query? never executes it";
       "[symbol: user; string|parse tree: query]";                  "boolean: permitted");
    (`requ;            1b; "permission-check a query as a user and execute it";
       "[symbol: user; string|parse tree: query]";                  "any: the query result");
    (`val;             1b; "evaluate a parse tree, under reval when read-only mode is on";
       "[parse tree: expression]";                                  "any: the result");
    (`valp;            1b; "evaluate a string or parse tree, under reval when read-only mode is on";
       "[string|parse tree: expression]";                           "any: the result");
    (`execas;          1b; "run a query as another user, subject to that user's permissions";
       "[string|parse tree: query; symbol: user]";                  "any: the query result");
    (`admin;           1b; "grant administration sub-api - see the admin.* rows below for members";
       "[dict of functions, keyed by name]";                        "dict: the admin functions");
    (`loadpermissions; 1b; "load the grant cascade (default, proctype, procname) from grantdirs";
       "[]";                                                        "null");
    (`unblock;         1b; "clear a user's ldap lockout";
       "[symbol: user]";                                            "null");
    / the admin sub-api, enumerated rather than hidden behind one opaque entry. public:0b - real
    / callables in di.api's full view, kept out of the public summary, which lists `admin itself
    (`admin.adduser;             0b; "register a user with an authentication method and a hashed password";
       "[symbol: user; symbol: authtype (local|ldap); symbol: hashtype (md5); string: hashed password]"; "null");
    (`admin.removeuser;          0b; "remove a user entirely"; "[symbol: user]"; "null");
    (`admin.cloneuser;           0b; "copy a user's auth method plus group and role membership onto a new id";
       "[symbol: source; symbol: new user; string: password]"; "null");
    (`admin.addgroup;            0b; "create a group, which grants table and variable access"; "[symbol: group; string: description]"; "null");
    (`admin.removegroup;         0b; "remove a group"; "[symbol: group]"; "null");
    (`admin.addtogroup;          0b; "add a user (or a group) to a group; membership is transitive";
       "[symbol: user or group; symbol: group]"; "null");
    (`admin.removefromgroup;     0b; "remove a user or group from a group"; "[symbol: user or group; symbol: group]"; "null");
    (`admin.addrole;             0b; "create a role, which grants the right to call functions"; "[symbol: role; string: description]"; "null");
    (`admin.removerole;          0b; "remove a role"; "[symbol: role]"; "null");
    (`admin.assignrole;          0b; "give a user a role"; "[symbol: user; symbol: role]"; "null");
    (`admin.unassignrole;        0b; "take a role away from a user"; "[symbol: user; symbol: role]"; "null");
    (`admin.addfunction;         0b; "put a function into a function group"; "[symbol: function; symbol: function group]"; "null");
    (`admin.removefunction;      0b; "take a function out of a function group"; "[symbol: function; symbol: function group]"; "null");
    (`admin.grantaccess;         0b; "grant an entity read or write access to a table or variable";
       "[symbol: object; symbol: entity; symbol: read or write]"; "null");
    (`admin.revokeaccess;        0b; "revoke a previously granted access"; "[symbol: object; symbol: entity; symbol: read or write]"; "null");
    (`admin.grantfunction;       0b; "grant a role the right to call a function, gated by a paramcheck";
       "[symbol: object; symbol: role; function: paramcheck]"; "null");
    (`admin.revokefunction;      0b; "revoke a function grant from a role"; "[symbol: object; symbol: role]"; "null");
    (`admin.createvirtualtable;  0b; "expose a filtered view of a table under a new name";
       "[symbol: name; symbol: table; list: where clause]"; "null");
    (`admin.removevirtualtable;  0b; "remove a virtual table"; "[symbol: name]"; "null");
    (`admin.addpublic;           0b; "track an auto provisioned anonymous user against its handle"; "[symbol: user; int: handle]"; "null");
    (`admin.removepublic;        0b; "stop tracking an anonymous user"; "[symbol: user]"; "null");
    (`admin.wildcard;            0b; "the wildcard object - grant against it for superuser rights"; "[]"; "symbol: the wildcard"));
  };
