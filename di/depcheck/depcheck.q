/ dependency, version, core-contract, and .z.ts ownership auditing for already-loaded kdb-x modules
/ this module never calls `use` on anything it checks - every check reads other modules' state purely by
/ introspecting the session namespace the kdb-x `use` loader already populates (`.m.di.0<shortname>`), so it stays
/ standalone with no hard di.* dependency of its own

/ the fixed set of core dependency contracts di.depcheck knows how to validate, keyed by the module that provides
/ each one - not a generic self-declaration registry, since no such mechanism exists anywhere in this codebase yet
contracts:`di.log`di.timer`di.handlers!(
  `info`warn`error;
  `addjob`deletejobs`enablejobs`disablejobs`getactivejobs`cp;
  `register`remove`list
  );

/ ============================================================
/ session-namespace introspection helpers
/ ============================================================

shortmod:{[modname]
  / di.timer -> `0timer ; kx.log -> `0log - the short form the kdb-x `use` loader keys a module under, off its
  / vendor's `.m.<vendor> namespace. Assumes exactly one dot (vendor.name), matching every module name seen in
  / this codebase so far
  `$"0",last "." vs string modname
  };

shorttofull:{[s]
  / `0timer -> `di.timer - only ever applied to keys of `.m.di (checkdeps walks di.* modules specifically, see
  / checkdeps), so the di. prefix is correct here and does not need vendor-generalising like shortmod/modvendorns
  `$"di.",1_string s
  };

modvendorns:{[modname]
  / di.timer -> `.m.di ; kx.log -> `.m.kx - the top-level session namespace a module's vendor is keyed under.
  / a di.* module's deps.q may legitimately declare a hard dependency on an external vendor module (e.g.
  / kx.log), so dependency resolution (getexport/checkonedep/checkcontract) must not hardcode `.m.di - only
  / checkdeps's walk of which modules to audit as consumers is intentionally di.*-scoped
  `$".m.",first "." vs string modname
  };

getexport:{[modname]
  / read another already-loaded module's export dict purely via session-namespace introspection - no `use`, no import
  / returns (::) if the module isn't loaded, or if its export somehow can't be read
  sn:shortmod modname;
  vns:modvendorns modname;
  if[not sn in key vns;:(::)];
  @[get;`$(string vns),".",(string sn),".export";{(::)}]
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
  / load <modname>'s deps.q - a single pure `deps:...` assignment, by convention (the only real precedent, di.merge,
  / has no other content) - and capture its value without leaving a stray global `deps` behind
  p:finddepsq modname;
  if[p~(::);:(::)];
  @[system;"l ",1_string p;{[e] (::)}];
  d:@[get;`deps;{(::)}];
  delete deps from `.;
  d
  };

/ ============================================================
/ deps.toml loading (lazy, file-existence-gated di.toml)
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
  / lazily resolve di.toml once and cache it in module state, returning its export dict. throws if di.toml is not
  / resolvable on QPATH - caught by readdepstoml and turned into one aggregated failure line, never an abort. only ever
  / called when a real deps.toml file has already been found, so a module with no deps.toml never triggers a di.toml load
  cached:@[get;`.z.m.tomlmod;{(::)}];
  if[not cached~(::);:cached];
  m:use`di.toml;
  .z.m.tomlmod:m;
  m
  };

readdepstoml:{[modname]
  / read <modname>/deps.toml if it exists, returning (failures;depsdict). di.toml is touched ONLY when the file exists
  / (file-existence-gated, exactly like di.config's parsefile checks existence before dispatching on extension). a missing
  / or broken di.toml degrades to one aggregated failure line worded like di.config's requiretoml (name the file/module,
  / name the underlying cause, one sentence) - but deliberately does NOT throw: di.config's requiretoml aborts its whole
  / cascade because it must return one complete config, whereas di.depcheck must surface every module's problems in one
  / pass, so it catches, records a line, and keeps walking (see depcheck.md)
  p:finddepstoml modname;
  if[p~(::);:(();()!())];
  path:1_string p;
  @[{[mn;pth]
      d:(resolvetoml[])[`parsefile] pth;
      / a well-formed manifest has a [dependencies] section (a dict); absent -> nothing declared; present but not a
      / dict (e.g. `dependencies = "x"` written as a scalar) is a clear authoring error, reported not merged (a
      / non-dict here would otherwise throw out of readdeps's merge and abort the whole walk)
      $[not `dependencies in key d;(();()!());
        99h=type d`dependencies;(();d`dependencies);
        (enlist "di.depcheck: deps.toml for ",(string mn),
          " has a malformed [dependencies] section - expected a table of module = \"version\" entries";()!())]
     }[modname;];
    path;
    {[mn;e] (enlist "di.depcheck: cannot read deps.toml for ",(string mn),
      " - the di.toml module was not found on QPATH or failed to parse it; di.toml is required to read .toml manifests (underlying: ",e,")";
      ()!())}[modname;]]
  };

readdeps:{[modname]
  / merged manifest reader: reads deps.q and deps.toml where each exists and merges them, with deps.toml winning on a key
  / clash - mirroring di.config's live parsetier ((parsefile base,".q"),parsefile base,".toml"). returns (failures;dict):
  / failures aggregates a malformed-deps.q line and/or an unreadable-deps.toml line; dict is the merged symbol->minversion
  / mapping (empty if neither format is present). all format-specific reading lives here and in finddepsq/finddepstoml -
  / every downstream function (checkonedep/checkmoduledeps/checkdeps/checkgraph) consumes only this already-merged dict
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
  / parse a "major.minor.patch" string into a 3-long int vector; a version that does not parse cleanly as three
  / all-numeric parts collapses to a single (0Ni;0Ni;0Ni) "malformed" sentinel, checked via ismalformed, rather
  / than left to silently participate in numeric comparison one component at a time - a lone bad component (e.g.
  / a pre-release tag like "1.2.3-rc1") used to null out only itself, which could silently make a real, newer
  / version compare as lower than it should, or make a typo'd deps.q minver like "abc" silently compare as no
  / real minimum at all. Caught by direct testing, not by reading the code - see depcheck.md
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
  / real numeric semver comparison only - no pre-release/build-metadata support, matching every version string seen
  / in this codebase so far (all plain X.Y.Z), unlike legacy TorQ's 5-component digit-walk
  pa:parsesemver a;
  pb:parsesemver b;
  diffs:pa<>pb;
  $[not any diffs;0i;[i:diffs?1b;$[pa[i]<pb[i];-1i;1i]]]
  };

vergte:{[a;b]
  / true if version a satisfies a minimum of b
  / NOTE: during 0.x.y development a passing >= check does not guarantee contract compatibility - minor bumps may
  / carry breaking changes pre-1.0 across this workstream. Implementing literal >= anyway, per the plan; this is a
  / known, accepted gap, not something this function tries to solve
  not -1i=vercmp[a;b]
  };

/ ============================================================
/ dependency presence/version checks
/ ============================================================

checkfoundversion:{[dep;minver;foundver]
  / dep is loaded and exports a version - compares it against the declared minimum
  / a malformed minver (a deps.q authoring typo) or malformed foundver (a module exporting a non-semver string)
  / is reported explicitly here rather than silently entering vergte's numeric comparison - see parsesemver
  if[ismalformed minver;
    :enlist string[dep]," has a declared minimum version of ",minver,", which is not a valid major.minor.patch version"];
  if[ismalformed foundver;
    :enlist string[dep]," exports version ",foundver,", which is not a valid major.minor.patch version"];
  $[vergte[foundver;minver];();enlist string[dep]," requires minimum version ",minver,", found ",foundver]
  };

checkdepversion:{[dep;minver]
  / dep is confirmed loaded - checks its exported version, if any, against minver
  / NOTE: sequential if[] early returns, not a single `or`-combined condition - q's `or`/`and` are eager vector
  / operators, not short-circuiting, so `(xp~(::)) or not `version in key xp` would evaluate `key xp` even when
  / xp is (::) and throw 'type. Caught by direct testing, not by reading the code - see depcheck.md
  xp:getexport dep;
  noversionmsg:enlist string[dep]," requires minimum version ",minver,", but ",string[dep]," exports no version";
  if[xp~(::);:noversionmsg];
  if[not `version in key xp;:noversionmsg];
  checkfoundversion[dep;minver;xp`version]
  };

checkonedep:{[dep;minver]
  / checks a single declared (dependency;minimum-version) pair against the current session
  / returns () on pass, or an enlisted failure line matching the plan's exact report format
  / not vendor-restricted to di.* - a deps.q may name an external vendor module (e.g. kx.log) as a hard
  / dependency, so presence is checked against dep's own vendor namespace, not hardcoded to `.m.di
  / a manifest version must be a string (quoted in deps.toml, a q string in deps.q). a non-string value - an unquoted
  / deps.toml version parsed as a float/int by di.toml, or a symbol/number in deps.q - is an authoring error reported
  / as its own clear line, rather than left to corrupt the concatenated message or throw out of parsesemver's `vs`.
  / 10h=abs type accepts a char vector or a lone char atom (both string-ish), rejecting int/float/symbol
  if[not 10h=abs type minver;
    :enlist string[dep]," has a non-string minimum version in its manifest (got type ",(string type minver),") - versions must be quoted strings"];
  depshort:shortmod dep;
  vns:modvendorns dep;
  $[not depshort in key vns;
    enlist string[dep]," requires minimum version ",minver,", not found";
    checkdepversion[dep;minver]]
  };

checkmoduledeps:{[modshort]
  / checks one already-loaded module's declared deps (deps.q and/or deps.toml) against the current session. returns
  / aggregated failure lines: manifest read-failures (a malformed deps.q or an unreadable deps.toml, both pre-collected
  / by readdeps rather than thrown) plus each declared dependency's presence/version line. one bad manifest never aborts
  / the checkdeps[] walk and masks other modules' real failures - readdeps catches, checkonedep is a pure per-pair function
  modname:shorttofull modshort;
  r:readdeps modname;
  merged:r 1;
  (r 0),$[0=count merged;();raze checkonedep'[key merged;value merged]]
  };

checkdeps:{[]
  / walks every loaded di.* module's deps.q and checks each declared dependency for presence and minimum version
  / "not found" here means a declared dependency was never `use`d into this session - this is a post-load audit,
  / not a QPATH filesystem scan (see depcheck.md for why)
  / if two different loaded modules declare the same dependency at different minimums, each is checked
  / independently and both lines are emitted if both fail - checkonedep is a pure function of (dep;minver) with
  / no shared state across calls, so this needs no special handling. Manually verified with two real deps.q
  / fixtures on disk (di.handlers required at both a satisfied and an unsatisfied minimum simultaneously) since
  / no real module ships a non-empty deps.q yet to build a committed, portable test against - see depcheck.md
  raze checkmoduledeps each key `.m.di
  };

/ ============================================================
/ transitive dependency-manifest graph walk
/ ============================================================

resolvemodule:{[modname]
  / reimplements the kdb-x `use` loader's QPATH search (colon-separated roots, first match wins; a dotted module name's
  / dots become path segments) to test whether a module is INSTALLED on QPATH without loading it - returns the resolved
  / module directory (hsym) or (::) if nothing matches. adapted from TorqX di.depcheck's resolvemodule; deliberately does
  / not reach into kdb-x's undocumented .Q.m.* internals. used only for transitive presence, distinct from checkonedep's
  / loaded-check: a module can be installed-on-QPATH yet not loaded-into-the-session
  relpath:ssr[string modname;".";"/"];
  roots:":" vs getenv`QPATH;
  exts:(".q";".k";".q_";".k_");
  dirs:{[rp;root] root,"/",rp}[relpath;] each roots;
  hit:{[dir;exts] any {[d;e] 0<count key hsym `$d,"/init",e}[dir;] each exts}[;exts] each dirs;
  $[any hit;hsym `$dirs first where hit;(::)]
  };

visit:{[covered;directdeps;acc;modname]
  / recursively visit one module in the manifest graph, cycle-guarded via acc`visited. reads the module's merged manifest
  / on disk (whether or not it is loaded), aggregates its read-failures ONLY if checkdeps did not already read it (i.e. it
  / is not a loaded root - avoids double-reporting), then for each declared dependency presence-checks it against QPATH
  / (reported only when it is not itself a direct dep of some loaded module - those are checkdeps' domain) and recurses in
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
  / transitive on-disk manifest walk from every loaded di.* module (our post-load analogue of "the process's entry
  / module"). reads each peer's deps.q/deps.toml - whether or not it is loaded - and recurses, cycle-guarded, reporting a
  / presence failure for any dependency reached at depth >= 2 that does not resolve on QPATH. depth-1 (deps directly
  / declared by a loaded module) stays with checkdeps (presence=loaded, version=exported); checkgraph excludes those via
  / the directdeps set so the two never double-report. satisfies consistency.md's on-disk / loads-no-module-code walk
  / without a pre-load pass. LIMITATION: transitive VERSION checking of an unloaded module is not done here - a found
  / version needs loading (forbidden) or a per-module VERSION file (deferred until a repo-wide rollout) - see depcheck.md
  roots:shorttofull each key `.m.di;
  directdeps:distinct raze {[r] key (readdeps r) 1} each roots;
  acc:`visited`fails!(`symbol$();());
  acc:{[covered;directdeps;acc;root] visit[covered;directdeps;acc;root]}[roots;directdeps]/[acc;roots];
  acc`fails
  };

/ ============================================================
/ core dependency contract checks
/ ============================================================

/ generic, exported primitive: checks whether a loaded module's export dict contains every key a given contract
/ requires. vendor-agnostic like checkonedep/getexport, though every current contracts entry happens to be
/ di.*-prefixed. usable for any provider/contract pair, not just the three known core dependencies checkcontracts[]
/ audits automatically below. never calls `use` - introspection only, matching this module's whole design; unlike
/ its TorqX counterpart of the same name, which does call `use` for real
/ requiredkeys accepts a single symbol atom as well as a vector - every internal caller (contracts, below) already
/ passes a vector, but this is now a public entry point for a caller auditing a contract of exactly one key, which
/ is naturally written as a bare symbol rather than remembering to `enlist` it - a real boundary this module didn't
/ have before it was exported. caught by direct testing, not by reading the code
checkcontract:{[provider;requiredkeys]
  requiredkeys:$[-11h=type requiredkeys;enlist requiredkeys;requiredkeys];
  sn:shortmod provider;
  vns:modvendorns provider;
  if[not sn in key vns;:()];
  xp:getexport provider;
  if[xp~(::);:enlist string[provider]," is loaded but its export dict could not be read"];
  missing:requiredkeys where not requiredkeys in key xp;
  $[0=count missing;();enlist string[provider]," is missing required contract key(s): ",", " sv string missing]
  };

checkcontracts:{[]
  / checks whichever of the known core-dependency providers (di.log/di.timer/di.handlers) are loaded in this session
  raze checkcontract'[key contracts;value contracts]
  };

/ ============================================================
/ .z.ts ownership check
/ ============================================================

ztscheck:{[]
  / warns if .z.ts is bound to something while di.timer either isn't loaded or doesn't look initialised
  / LIMITATION (accepted, warning-level only): di.timer's `enabled` flag being 1b is evidence its init ran and bound
  / .z.ts itself - it does NOT prove nothing has overwritten .z.ts since. di.timer assigns .z.ts directly (not via
  / di.handlers, which explicitly excludes .z.ts from its own scope), so there is no ownership marker to check
  / instead. Scope is deliberately limited to .z.ts only - whether this should ever cover other .z.* events is an
  / open question for di.handlers' owner, not decided here
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
  / compares the running kdb-x engine's major.minor (.z.K) against an optional minimum passed via deps`minkdbxversion
  / uses .z.K, matching di.k4unit's own precedent (`minver<=.z.K` gates which tests run) rather than parsing .z.v,
  / whose value on this box ("5.0.20260122") did not match the plan's assumed kdb-x product-semver shape and isn't
  / confirmed to be the same number as the product version shown in the kdb-x startup banner - see depcheck.md
  / warning-level, not fail-fast: there is no config cascade yet for di.depcheck to source a minimum from, so this
  / is opt-in via an extra key on the same `deps dict rather than a new config channel
  minversion:$[`minkdbxversion in key deps;deps`minkdbxversion;0Nf];
  if[null minversion;:()];
  if[.z.K>=minversion;:()];
  enlist "kdb-x engine version ",(string .z.K)," is below the configured minimum ",(string minversion),"."
  };

/ ============================================================
/ report formatting
/ ============================================================

buildreport:{[header;lines]
  / formats a bulleted, indented block under a header line, matching the plan's exact "HEADER:\n  line1\n  line2" shape
  header,":\n",sv["\n";"  ",/:lines]
  };

/ ============================================================
/ public api
/ ============================================================

init:{[deps]
  / initialise di.depcheck - validate the required log dependency, then audit the current session: dependency
  / presence/version, core-dependency-contract shape, .z.ts ownership, and (optionally) a minimum kdb-x engine
  / version. deps: a dict with a required `log key (binary `info`warn`error functions, per consistency.md) and an
  / optional `minkdbxversion float
  if[99h<>type deps;'"di.depcheck: deps must be a dict with `log key"];
  if[not `log in key deps;'"di.depcheck: log dependency is required; pass `info`warn`error functions - see di.log"];
  if[99h<>type deps`log;'"di.depcheck: log value must be a dict; pass `info`warn`error functions"];
  if[not all `info`warn`error in key deps`log;
    '"di.depcheck: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  .z.m.loginfo:(deps`log)`info;
  .z.m.logwarn:(deps`log)`warn;
  .z.m.logerr:(deps`log)`error;

  failures:checkdeps[],checkgraph[],checkcontracts[];
  warnings:ztscheck[],kdbxcheck[deps];

  / warnings are logged unconditionally, before the failures check below - not gated behind "no failures", so a
  / real warning is never silently dropped just because a failure also happened to signal in the same call.
  / caught by direct testing, not by reading the code - see depcheck.md
  if[count warnings;
    .z.m.logwarn[`depcheck;buildreport["WARNING";warnings]]];

  if[count failures;
    report:buildreport["DEPENDENCY CHECK FAILED";failures];
    .z.m.logerr[`depcheck;report];
    '"di.depcheck: ",report];

  .z.m.loginfo[`depcheck;"dependency check complete: ",(string count failures)," failure(s), ",(string count warnings)," warning(s)"];
  };
