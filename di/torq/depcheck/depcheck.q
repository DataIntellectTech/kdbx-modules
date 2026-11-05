/ audit loaded kdb-x modules: dependency presence and version, core contracts and .z.ts ownership,
/ by introspecting the session namespaces the `use` loader populates

/ module version

/ core dependency contracts: provider module -> required export keys
contracts:`di.util.log`di.timer`di.torq.handlers!(
  `info`warn`error;
  `addjob`deletejobs`enablejobs`disablejobs`getactivejobs;
  `register`remove`list
  );

/ ============================================================
/ session-namespace introspection helpers
/ ============================================================
/ the `use` loader nests a module's segments after the vendor with a 0 prefix:
/ di.timer -> .m.di.0timer, di.torq.handlers -> .m.di.0torq.0handlers

shortmod:{[modname]
  / di.torq.handlers -> `0handlers - the leaf short name, the key a module sits under within its PARENT namespace
  `$"0",last "." vs string modname
  };

modparentns:{[modname]
  / the PARENT session namespace a module is keyed under: di.timer -> `.m.di ; di.torq.handlers -> `.m.di.0torq ;
  / kx.log -> `.m.kx. Every segment except the vendor and the leaf becomes a `0`-prefixed namespace segment.
  p:"." vs string modname;
  `$".m.",(first p),(raze ".0",/:1_-1_p)
  };

modns:{[modname]
  / a module's OWN full session namespace: di.timer -> `.m.di.0timer ; di.torq.handlers -> `.m.di.0torq.0handlers
  ` sv modparentns[modname],shortmod modname
  };

nspathtomod:{[nspath]
  / inverse of modns: `.m.di.0torq.0handlers -> `di.torq.handlers
  s:2_"." vs string nspath;
  `$"." sv (enlist first s),{$["0"=first x;1_x;x]} each 1_s
  };

getexport:{[modname]
  / a loaded module's export dict, or (::) if not loaded or unreadable
  sn:shortmod modname;
  pns:modparentns modname;
  if[not sn in key pns;:(::)];
  @[get;` sv (modns modname),`export;{(::)}]
  };

loadedmodules:{[]
  / every loaded di.* module's full name, walking the nested .m.di tree
  walk:{[walk;acc;nsp]
    ks:@[key;nsp;{`$()}];
    acc:$[`export in ks; acc,nspathtomod nsp; acc];
    childns:ks where ks like "0*";
    walk[walk;;]/[acc; ` sv' nsp,'childns]
    };
  walk[walk;();`.m.di]
  };

/ ============================================================
/ deps.q loading
/ ============================================================

finddepsq:{[modname]
  / locate <modname>/deps.q on QPATH (colon-separated, like PATH); returns its file path, or (::) if the module ships none
  relpath:(ssr[string modname;".";"/"]),"/deps.q";
  roots:":" vs getenv`QPATH;
  paths:{[relpath;root] hsym `$root,"/",relpath}[relpath;] each roots;
  found:paths where not {[p] ()~key p} each paths;
  $[0=count found;(::);first found]
  };

readdepsq:{[modname]
  / load <modname>'s deps.q and return its `deps value
  p:finddepsq modname;
  if[p~(::);:(::)];
  @[system;"l ",1_string p;{[e] (::)}];
  d:@[get;`deps;{(::)}];
  delete deps from `.;
  d
  };

/ ============================================================
/ deps.toml loading (lazy, file-existence-gated di.util.toml)
/ ============================================================

finddepstoml:{[modname]
  / locate <modname>/deps.toml on QPATH - sibling of finddepsq; returns its file path, or (::) if the module ships none
  relpath:(ssr[string modname;".";"/"]),"/deps.toml";
  roots:":" vs getenv`QPATH;
  paths:{[relpath;root] hsym `$root,"/",relpath}[relpath;] each roots;
  found:paths where not {[p] ()~key p} each paths;
  $[0=count found;(::);first found]
  };

resolvetoml:{[]
  / load and cache di.util.toml, returning its export dict; signals if unavailable
  cached:@[get;`.z.m.tomlmod;{(::)}];
  if[not cached~(::);:cached];
  m:use`di.util.toml;
  .z.m.tomlmod:m;
  m
  };

readdepstoml:{[modname]
  / read <modname>/deps.toml if it exists, returning (failures;depsdict); an unreadable file
  / is a failure line, not an error
  p:finddepstoml modname;
  if[p~(::);:(();()!())];
  path:1_string p;
  @[{[mn;pth]
      d:(resolvetoml[])[`parsefile] pth;
      / a non-dict [dependencies] is a failure line
      $[not `dependencies in key d;(();()!());
        99h=type d`dependencies;(();d`dependencies);
        (enlist "di.torq.depcheck: deps.toml for ",(string mn),
          " has a malformed [dependencies] section - expected a table of module = \"version\" entries";()!())]
     }[modname;];
    path;
    {[mn;e] (enlist "di.torq.depcheck: cannot read deps.toml for ",(string mn),
      " - the di.util.toml module was not found on QPATH or failed to parse it; di.util.toml is required to read .toml manifests (underlying: ",e,")";
      ()!())}[modname;]]
  };

readdeps:{[modname]
  / read and merge deps.q and deps.toml, .toml winning on a clash; returns (failures;dict)
  dq:readdepsq modname;
  qmalformed:(not dq~(::)) and not 99h=type dq;
  qdict:$[qmalformed or dq~(::);()!();dq];
  tr:readdepstoml modname;
  malfail:$[qmalformed;enlist string[modname]," deps.q is malformed - expected a dict, got type ",string type dq;()];
  (malfail,tr 0;qdict,tr 1)
  };

/ ============================================================
/ semver comparison
/ ============================================================

parsesemver:{[v]
  / parse "major.minor.patch" to 3 ints, or (0Ni;0Ni;0Ni) if any part is not numeric
  parts:"." vs v;
  if[not 3=count parts;:3#0Ni];
  nums:{@[{"I"$x};x;0Ni]} each parts;
  $[any null nums;3#0Ni;nums]
  };

ismalformed:{[v]
  / true if v does not parse as a clean major.minor.patch triple - see parsesemver
  (3#0Ni)~parsesemver v
  };

vercmp:{[a;b]
  / -1/0/1 comparing semver strings a and b by (major,minor,patch); a null component sorts lowest
  pa:parsesemver a;
  pb:parsesemver b;
  diffs:pa<>pb;
  $[not any diffs;0i;[i:diffs?1b;$[pa[i]<pb[i];-1i;1i]]]
  };

vergte:{[a;b]
  / true if version a satisfies a minimum of b
  not -1i=vercmp[a;b]
  };

/ ============================================================
/ dependency presence/version checks
/ ============================================================

checkfoundversion:{[dep;minver;foundver]
  / compare a loaded dep's version with the declared minimum, reporting malformed versions
  if[ismalformed minver;
    :enlist string[dep]," has a declared minimum version of ",minver,", which is not a valid major.minor.patch version"];
  if[ismalformed foundver;
    :enlist string[dep]," exports version ",foundver,", which is not a valid major.minor.patch version"];
  $[vergte[foundver;minver];();enlist string[dep]," requires minimum version ",minver,", found ",foundver]
  };

checkdepversion:{[dep;minver]
  / check a loaded dep's exported version, if any, against minver
  xp:getexport dep;
  noversionmsg:enlist string[dep]," requires minimum version ",minver,", but ",string[dep]," exports no version";
  ver:$[xp~(::);"";$[`version in key xp;xp`version;""]];
  / fall back to the on-disk VERSION file when a loaded module does not export `version
  if[0=count ver;
    dir:resolvemodule dep;
    if[not dir~(::);ver:readversion dir]];
  / neither source carries a version
  if[0=count ver;:noversionmsg];
  checkfoundversion[dep;minver;ver]
  };

checkonedep:{[dep;minver]
  / check one declared (dependency;minimum-version) pair against the session, for any vendor;
  / returns () on pass or an enlisted failure line; a non-string version is a failure line
  if[not 10h=abs type minver;
    :enlist string[dep]," has a non-string minimum version in its manifest (got type ",(string type minver),") - versions must be quoted strings"];
  depshort:shortmod dep;
  vns:modparentns dep;
  $[not depshort in key vns;
    enlist string[dep]," requires minimum version ",minver,", not found";
    checkdepversion[dep;minver]]
  };

checkmoduledeps:{[modname]
  / check one loaded module's declared deps (deps.q and/or deps.toml) against the session;
  / takes a full dotted module name; returns aggregated failure lines
  r:readdeps modname;
  merged:r 1;
  (r 0),$[0=count merged;();raze checkonedep'[key merged;value merged]]
  };

checkdeps:{[]
  / check every loaded di.* module's declared deps for presence (loaded) and minimum version
  raze checkmoduledeps each loadedmodules[]
  };

/ ============================================================
/ transitive dependency-manifest graph walk
/ ============================================================

resolvemodule:{[modname]
  / resolve a module's directory on QPATH without loading it, or (::) if not installed
  relpath:ssr[string modname;".";"/"];
  roots:":" vs getenv`QPATH;
  exts:(".q";".k";".q_";".k_");
  dirs:{[rp;root] root,"/",rp}[relpath;] each roots;
  hit:{[dir;exts] any {[d;e] 0<count key hsym `$d,"/init",e}[dir;] each exts}[;exts] each dirs;
  $[any hit;hsym `$dirs first where hit;(::)]
  };

visit:{[covered;directdeps;acc;modname]
  / visit one module in the on-disk manifest graph, cycle-guarded, reporting deps that do not resolve
  / on QPATH (excluding direct deps of loaded modules) and recursing
  if[modname in acc`visited;:acc];
  acc[`visited]:acc[`visited],modname;
  r:readdeps modname;
  if[not modname in covered;acc[`fails]:acc[`fails],r 0];
  deps:key r 1;
  f:{[covered;directdeps;parent;acc;dep]
    rd:$[(not dep in directdeps) and (::)~resolvemodule dep;
      enlist string[dep]," is required transitively by ",(string parent)," but was not found on QPATH";
      ()];
    acc[`fails]:acc[`fails],rd;
    visit[covered;directdeps;acc;dep]
    }[covered;directdeps;modname];
  f/[acc;deps]
  };

checkgraph:{[]
  / transitive on-disk manifest walk from every loaded di.* module, reporting deps at depth >= 2
  / that do not resolve on QPATH
  roots:loadedmodules[];
  directdeps:distinct raze {[r] key (readdeps r) 1} each roots;
  acc:`visited`fails!(`symbol$();());
  acc:{[covered;directdeps;acc;root] visit[covered;directdeps;acc;root]}[roots;directdeps]/[acc;roots];
  acc`fails
  };

/ ============================================================
/ pre-load transitive VERSION graph (on-disk, loads no module code)
/ ============================================================
/ run before any module is loaded: resolve each declared dependency on QPATH and check its
/ VERSION file, walking manifests transitively

readversion:{[dir]
  / a resolved module directory's VERSION file contents, or "" if it has none
  vfile:hsym `$(string dir),"/VERSION";
  if[0=count key vfile;:""];
  first read0 vfile
  };

checkinstalledversion:{[requiringmod;dep;minver]
  / is dep installed on QPATH with an on-disk VERSION meeting minver; requiringmod attributes the failure
  / (` for the app manifest); returns () or an enlisted failure line
  ctx:$[null requiringmod;"";"(required by ",string[requiringmod],") "];
  if[not 10h=abs type minver;
    :enlist ctx,string[dep]," has a non-string minimum version in its manifest (got type ",(string type minver),")"];
  dir:resolvemodule dep;
  if[dir~(::);:enlist ctx,string[dep]," requires minimum version ",minver,", not found on QPATH"];
  have:readversion dir;
  if[0=count have;:enlist ctx,string[dep]," has no VERSION file at ",string dir];
  if[ismalformed minver;:enlist ctx,string[dep]," has an invalid minimum version ",minver];
  if[ismalformed have;:enlist ctx,string[dep]," has an invalid VERSION file (",have,") at ",string dir];
  $[vergte[have;minver];();enlist ctx,string[dep]," requires minimum version ",minver,", found ",have]
  };

visitversion:{[acc;modname]
  / version-check modname's declared deps against their VERSION files and recurse, cycle-guarded
  if[modname in acc`visited;:acc];
  acc[`visited]:acc[`visited],modname;
  r:readdeps modname;
  acc[`fails]:acc[`fails],r 0;
  merged:r 1;
  acc[`fails]:acc[`fails],raze checkinstalledversion[modname;;]'[key merged;value merged];
  {[acc;dep] visitversion[acc;dep]}/[acc;key merged]
  };

raisefails:{[fails]
  if[count fails;'"DEPENDENCY CHECK FAILED (peer version requirements):\n","\n" sv "  ",/:fails];
  ()!()
  };

checkversiongraph:{[entries]
  / version graph from a set of entry module names; signals on any failure
  acc:`visited`fails!(`symbol$();());
  raisefails (({[acc;e] visitversion[acc;e]}/[acc;entries])`fails)
  };

readmanifestfile:{[path]
  / a deps.toml file's [dependencies] dict; empty if absent or undeclared
  probe:hsym `$path;
  if[0=count key probe;:()!()];
  d:(resolvetoml[])[`parsefile] path;
  $[`dependencies in key d;d`dependencies;()!()]
  };

checkversiongraphfile:{[requiringmod;manifestpath]
  / version graph rooted at a manifest file; no-op if absent
  deps:readmanifestfile manifestpath;
  acc:`visited`fails!(`symbol$();());
  acc[`fails]:raze checkinstalledversion[requiringmod;;]'[key deps;value deps];
  raisefails (({[acc;dep] visitversion[acc;dep]}/[acc;key deps])`fails)
  };

/ ============================================================
/ core dependency contract checks
/ ============================================================

/ check that a loaded module's export dict has every required key; requiredkeys: symbol or symbols
checkcontract:{[provider;requiredkeys]
  requiredkeys:$[-11h=type requiredkeys;enlist requiredkeys;requiredkeys];
  sn:shortmod provider;
  vns:modparentns provider;
  if[not sn in key vns;:()];
  xp:getexport provider;
  if[xp~(::);:enlist string[provider]," is loaded but its export dict could not be read"];
  missing:requiredkeys where not requiredkeys in key xp;
  $[0=count missing;();enlist string[provider]," is missing required contract key(s): ",", " sv string missing]
  };

checkcontracts:{[]
  / checks whichever of the known core-dependency providers (di.util.log/di.timer/di.torq.handlers) are loaded in this session
  raze checkcontract'[key contracts;value contracts]
  };

/ ============================================================
/ .z.ts ownership check
/ ============================================================

ztscheck:{[]
  / warn if .z.ts is bound while di.timer is not loaded or not enabled
  bound:not (::)~@[get;`.z.ts;{(::)}];
  if[not bound;:()];
  timerowns:(`0timer in key `.m.di) and 1b~@[get;`.m.di.0timer.enabled;0b];
  if[timerowns;:()];
  enlist ".z.ts has been directly assigned outside di.timer. This may cause timer conflicts."
  };

/ ============================================================
/ kdb-x engine version check
/ ============================================================

kdbxcheck:{[deps]
  / warn if the engine's major.minor (.z.K) is below deps`minkdbxversion, if given
  minversion:$[`minkdbxversion in key deps;deps`minkdbxversion;0Nf];
  if[null minversion;:()];
  if[.z.K>=minversion;:()];
  enlist "kdb-x engine version ",(string .z.K)," is below the configured minimum ",(string minversion),"."
  };

/ ============================================================
/ report formatting
/ ============================================================

buildreport:{[header;lines]
  / a header line followed by indented lines
  header,":\n",sv["\n";"  ",/:lines]
  };

/ ============================================================
/ public api
/ ============================================================

init:{[deps]
  / validate the required `log dep and audit the session: dependencies, contracts, .z.ts ownership,
  / and engine version if `minkdbxversion is given
  if[99h<>type deps;'"di.torq.depcheck: deps must be a dict with `log key"];
  if[not `log in key deps;'"di.torq.depcheck: log dependency is required; pass `info`warn`error functions - see di.util.log"];
  if[99h<>type deps`log;'"di.torq.depcheck: log value must be a dict; pass `info`warn`error functions"];
  if[not all `info`warn`error in key deps`log;
    '"di.torq.depcheck: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  .z.m.loginfo:(deps`log)`info;
  .z.m.logwarn:(deps`log)`warn;
  .z.m.logerr:(deps`log)`error;

  failures:checkdeps[],checkgraph[],checkcontracts[];
  warnings:ztscheck[],kdbxcheck[deps];

  / log warnings before signalling any failures
  if[count warnings;
    .z.m.logwarn[`depcheck;buildreport["WARNING";warnings]]];

  if[count failures;
    report:buildreport["DEPENDENCY CHECK FAILED";failures];
    .z.m.logerr[`depcheck;report];
    '"di.torq.depcheck: ",report];

  .z.m.loginfo[`depcheck;"dependency check complete: ",(string count failures)," failure(s), ",(string count warnings)," warning(s)"];
  };
