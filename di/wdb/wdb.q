/ the write database: subscribe to a tickerplant, replay the day's log, accumulate live updates in
/ memory, periodically flush each table to a working directory partitioned by date, and at end of day
/ sort that data, move it into the hdb and tell the rdb/hdb processes to reload.
/ ported from TorQ's code/processes/wdb.q plus code/wdb/origstartup.q, code/wdb/writedown.q and the
/ .save section of code/common/dbwriteutils.q. see wdb.md for scope, divergences and rationale.
/ the version lives in the VERSION file and is read by init.q
/ ROOT-NAMESPACE RULES (the same ones that bit every process-tier module so far). a source-level bare
/ identifier in module code is rewritten at load to this module's private namespace, so it can never
/ reach root. therefore:
/   - reading a root table is a bare `value t` / `tables[`.]` - those fall through to root
/   - writing, clearing or dropping targets root EXPLICITLY via @[`.;t;...]
/   - the root entry points (upd, endofday, endofperiod, .u.end, wdbreloadhandler) are installed with
/     an explicit @[`.;...] or set[...], never a bare assignment
/ a q-sql select/where/by CLAUSE additionally cannot resolve a module-level name at all, so every
/ module value used in one is hoisted into a function-local first

/ ============================================================
/ constants (load-time)
/ ============================================================

/ the only process mode this version supports. `save and `sort are NOT trivial variants - see
/ requiremode and wdb.md design decision 9
supportedmode:`saveandsort;

/ the only writedown mode this version supports. the parted modes need di.merge's dispatch, deferred
supportedwritedownmode:`default;

/ tracks how much of each table has been written to the working partition this cycle. drives
/ tablelist's largest-first ordering - TorQ writedown.q:25
tabsizesschema:([tablename:`symbol$()]
  rowcount:`long$();
  bytes:`long$());

/ tracks each process this wdb has asked to reload, and whether it answered - TorQ wdb.q:269
reloadsummaryschema:([handle:`int$()]
  process:`symbol$();
  status:`boolean$();
  result:`symbol$());

/ the tickerplant-side selection algorithm handed to di.servers.gethandlebytype
defaultselection:`any;

/ ============================================================
/ internal helpers - config coercion
/ ============================================================

assym:{[k;x]
  / config values arrive as symbols from a .q settings file or as strings from a .toml one. `$ throws
  / 'type on a symbol, so it is NOT idempotent - hence the type check rather than a blanket cast.
  / BINARY like every other coercion helper here, naming the offending key: a dict or table used to
  / pass through this UNCHANGED with no comment explaining why, which is not a shape any real caller
  / (mode, writedownmode, tickerplanttypes, subtabs/subsyms, hdbtypes/rdbtypes/gatewaytypes/ignorelist/
  / reloadorder) could sensibly hand it - and for mode/writedownmode specifically it would have failed
  / later inside requiremode's own `string[m]` error construction rather than with this clear message
  if[(99h=type x) or 98h=type x;
    '"di.wdb: ",string[k]," must be a symbol or a string naming one; got: ",.Q.s1 x];
  :$[11h=abs type x;x;`$x];
  };

aslist:{[x]
  / normalise an atom to a one-element list. deliberately NOT applied to subtabs/subsyms: ` there is
  / the all-tables/all-syms SENTINEL, and di.subscriptions tests it with x~` (an atom match), so
  / enlisting it would turn "everything" into "the table literally named `"
  :$[0>type x;enlist x;x];
  };

ashsym:{[k;x]
  / normalise a directory setting to an hsym, accepting `:hdb, `hdb, ":hdb" or "hdb", naming the key
  / when it is none of those. BINARY like asbool/aslong below, and for the same reason: without the
  / key name the caller cannot tell which setting was rejected.
  / the type check is not cosmetic - a bare `string x` accepts anything that stringifies, so 42 would
  / silently become `:42 and the day's data would land under a directory nobody asked for
  if[not (type x) in -11 -10 10h;
    '"di.wdb: ",string[k]," must be a symbol or a string naming one directory; got: ",.Q.s1 x];
  s:$[10h=abs type x;(),x;string x];
  / the leading : is stripped BEFORE the empty check, so both ways of naming nothing are caught by
  / one guard: an empty value coerces to a bare ` (whose 1_string is "", the working directory) and a
  / lone ":" strips to exactly the same thing
  p:$[":"=first s;1_s;s];
  if[0=count p;
    '"di.wdb: ",string[k]," must name a directory; got an empty value: ",.Q.s1 x];
  :hsym `$p;
  };

asbool:{[k;x]
  / coerce ONE config value to a boolean ATOM, naming the key when it cannot be. a bare `boolean$ is
  / not safe: config values can arrive as strings, and `boolean$"true" is 1111b - a four-element
  / VECTOR that init would accept silently and that would then throw a bare 'type at the first save
  b:@[{`boolean$x};x;{[e] :()}];
  if[not -1h=type b;
    '"di.wdb: ",string[k]," must be a boolean; got: ",.Q.s1 x];
  :b;
  };

aslong:{[k;x]
  / coerce ONE config value to a long ATOM, naming the key when it cannot be. "j"$ on a STRING casts
  / each char to its ascii code rather than parsing the number, so "30000" would become a vector.
  / the two checks are NESTED rather than combined with `or`: q evaluates both sides of `or` eagerly
  / and `null` of the () sentinel is an empty BOOLEAN LIST, not a boolean
  n:@[{"j"$x};x;{[e] :()}];
  msg:"di.wdb: ",string[k]," must be a whole number; got: ",.Q.s1 x;
  if[not -7h=type n;'msg];
  if[null n;'msg];
  :n;
  };

astabdict:{[k;x]
  / coerce a per-table row-limit override to a TYPED tablename!long dict, naming the key when it
  / cannot be.
  / the empty case is the one that matters. ()!() is a perfectly reasonable way to write "no per-table
  / overrides", but an UNTYPED empty dict indexes to the general null :: rather than a long null, and
  / maxrows' `numrows^numtab t` then throws a bare 'type on the FIRST save rather than falling back to
  / numrows (measured). the typed empty dict yields 0N, which ^ fills correctly
  if[99h<>type x;
    '"di.wdb: ",string[k]," must be a dict of tablename!rowcount"];
  if[0=count x;:(`$())!`long$()];
  v:@[{`long$x};value x;{[e] :()}];
  if[not 7h=type v;
    '"di.wdb: ",string[k]," values must be whole numbers; got: ",.Q.s1 value x];
  :(key x)!v;
  };

astimespan:{[k;x]
  / coerce ONE config value to a timespan atom. settimer and eodwaittime are written as 0D00:00:10 in
  / a .q settings file but arrive as a string or an int from other config sources
  n:@[{"n"$x};x;{[e] :()}];
  msg:"di.wdb: ",string[k]," must be a timespan; got: ",.Q.s1 x;
  if[not -16h=type n;'msg];
  if[null n;'msg];
  :n;
  };

cfg:{[deps;dflts;k]
  / internal - resolve ONE config key off the single deps dict, falling back to its default. every
  / write in init stays an explicit .z.m.<name>: line so a reviewer can grep which keys reach module
  / state; this only removes the repeated $[k in key deps;deps k;dflts k] from each of them
  :$[k in key deps;deps k;dflts k];
  };

configdefaults:{[]
  / every config key init accepts, with its default, taken from TorQ config/settings/wdb.q and the
  / @[value;`var;default] guards at the top of wdb.q / writedown.q. this is the single place the
  / defaults live, and the test suite asserts every key here reached module state - which is what
  / catches a forgotten write in init.
  / NB built as ONE key!value pair, not a chain of joined single-group dicts: joining dicts whose
  / value sides are differently typed throws 'type.
  / NB three defaults differ from config/settings/wdb.q, deliberately:
  /   mode              - that file sets `save, which is the DEFERRED split-worker architecture, not
  /                       a variant of `saveandsort (see requiremode and wdb.md decision 9). the
  /                       code-level default `saveandsort is the one v1 implements
  /   tickerplanttypes  - that file sets `segmentedtickerplant, which is site-specific. a module
  /                       default should be the generic code-level one, as di.rdb's also is
  /   reloadorder       - the code default is `hdb`rdb`idb; `idb is dropped with the IDB tier
  / NB replaynumrows/replaynumtab are listed here so the completeness test covers them, but init
  / resolves them against the RESOLVED numrows/numtab rather than these static values - see init
  k:`tickerplanttypes`hdbtypes`rdbtypes`gatewaytypes`ignorelist,
    `subtabs`subsyms`schema`replay,
    `savedir`hdbdir`sortcsv,
    `numrows`numtab`replaynumrows`replaynumtab,
    `partitiontype`immediate`settimer,
    `mode`writedownmode,
    `reloadorder`permitreload`gc`eodwaittime,
    `tpconnsleepintv`tpcheckcycles,
    `upd`savedownmanipulation`postreplay;
  v:(enlist`tickerplant;enlist`hdb;enlist`rdb;`$();`heartbeat`logmsg;
     `;`;1b;1b;
     `:temphdb;`:hdb;`;
     100000;`quote`trade!10000 50000;100000;`quote`trade!10000 50000;
     `date;0b;0D00:00:10;
     supportedmode;supportedwritedownmode;
     `hdb`rdb;1b;1b;0D00:00:10.000;
     10;0W;
     updfn;()!();{[d;p] });
  :k!v;
  };

normpath:{[p]
  / normalise a path to forward-slash kdb form, preserving the leading colon and the input type - the
  / port of TorQ's .os.pthq (code/common/os.q:23), whose ONLY caller in the whole TorQ repo is
  / wdb.q:89-90 normalising savedir/hdbdir at load.
  / NB di.osutil.topath is NOT a substitute - it goes the opposite way (kdb form -> OS-native separators)
  / and strips the leading colon. growing di.os's public surface for a single wdb-only need was the
  / worse trade, so this is two lines here instead. identity on linux; it exists for windows configs
  / written with backslashes
  :$[10h=abs type p;ssr[(),p;"\\";"/"];`$ssr[string p;"\\";"/"]];
  };

/ ============================================================
/ internal helpers - lifecycle and errors
/ ============================================================

initialised:{[]
  / has init run? a direct (module-rewritten) reference detects prior setup without touching root.
  / hdbdir is deliberately NOT given a module-level default - its only value comes from init, so this
  / probe cannot be fooled by a load-time constant of the same name
  :@[{.z.m.hdbdir;1b};::;{[e] :0b}];
  };

requireinit:{[ctx]
  / every exported function except init depends on init having wired the logger. there is no default
  / logger, so without this an early call dies with a bare 'type instead of a usable message
  if[not initialised[];
    '"di.wdb: ",string[ctx],": init must be called before any other function"];
  };

iscallable:{[x]
  / internal - is x a genuinely callable value? 100 112h spans every callable form (lambda, primitive,
  / operator, iterator, projection, composition), but 101h - the UNARY PRIMITIVE class, which the
  / generic null :: shares with neg and count - sits INSIDE that range, so the bare range check is not
  / enough. that matters because :: is exactly what a function-valued dict hands back for a MISSING
  / key: an absent timer`deletejobs would otherwise pass init, and teardown's @[...] would then stop
  / being protected-apply at all (see teardown)
  t:type x;
  :(t within 100 112h) and 101h<>t;
  };

raiseerror:{[ctx;msg]
  / log an error under ctx then signal it, so a failure is observable in the log and not only as a
  / throw. init's own dependency validation is the one exception - the logger is not wired yet
  .z.m.logerr[ctx;msg];
  '"di.wdb: ",string[ctx],": ",msg;
  };

/ ============================================================
/ root entry points
/ ============================================================

updfn:{[t;x]
  / the default root upd. TorQ's is a bare `insert` (wdb.q:62, config/settings/wdb.q:50); this
  / reproduces INSERT semantics (append, not upsert-by-key) but targets root explicitly, and
  / normalises the three payload shapes a subscriber sees: a table from the live feed, a column DICT,
  / or a plain list of columns from the -11! log replay.
  / overridable with the `upd config key.
  / NB the append MUST go through the four-argument amend @[`.;t;,;data], not a unary lambda doing
  / tab,data - the lambda form returns a NEW table and silently drops every column attribute, so a
  / `g#sym column comes back unattributed after one update and stays that way all day
  @[`.;t;,;$[98h=type x;x;99h=type x;flip x;flip (cols value t)!x]];
  };

replayupd:{[t;x]
  / the root upd used DURING the tickerplant log replay. wraps the configured upd and flushes the
  / table as soon as it passes its REPLAY row limit - TorQ wdb.q:588-593. without this a whole day of
  / replayed messages accumulates in memory at once, which is the entire reason the wdb has a
  / separate replay limit
  .z.m.upd[t;x];
  replaymaxrowcheck[t;replaymaxrows t];
  };

publishroot:{[nm;f]
  / internal - publish ONE root entry point, warning first when the name already holds something that
  / is neither the function about to be installed nor the one this module installed last time.
  / uninstallroot deliberately refuses to delete a binding that is not ours; installing over one
  / silently is that same asymmetry in reverse, and it is how a co-hosted process loses its own upd
  / without a word. comparing against rootinstalled as well as against f keeps a legitimate re-init
  / QUIET when the `upd config key itself changed - root then holds the previous OURS, not a stranger's
  / NB .z.m.rootinstalled nm is a dict application that may miss - on the very first install ever,
  / .z.m.rootinstalled is still the empty typed dict init seeds it to. that does NOT throw: applying
  / an EMPTY dict to any key returns the generic empty list (), not a 'domain/'length error - verified
  / directly, since a wrong guess here would make this guard fail exactly when a foreign binding is
  / genuinely present, which is the one case it exists to catch
  if[nm in key `.;
    cur:`. nm;
    if[not any (f;.z.m.rootinstalled nm)~\:cur;
      .z.m.logwarn[`installroot;"root ",(string nm)," was already bound to something di.wdb did not ",
        "install - replacing it. teardown will not give the previous binding back"]]];
  @[`.;nm;:;f];
  };

installroot:{[]
  / publish the entry points the rest of the stack calls this process on. all explicit root targets:
  /   upd               - driven by the live feed AND by di.subscriptions' -11! replay
  /                       (requirerootupd refuses to replay without one), so it must exist before start
  /   endofday          - the tickerplant's (`endofday;date) broadcast
  /   endofperiod       - the tickerplant's intraday period roll
  /   .u.end            - TorQ's alias for endofday (wdb.q:666-668); set[] rather than @[`.;...]
  /                       because a dotted name is not a key of the root namespace dictionary
  /   wdbreloadhandler  - the reload REPLY callback. this one is not optional plumbing: a reloading
  /                       process runs the lambda reloadproc sent it and answers with an async
  /                       (name;args) message, which the default .z.ps evaluates in ROOT. module
  /                       functions live in private .z.m and cannot be reached by name, so without a
  /                       root binding every reply would die with an unresolved name and the roll
  /                       would hang until the timeout. legacy names it `.wdb.handler; a plain root
  /                       name is used here because we author the lambda that names it, and a .wdb.*
  /                       namespace is what this migration moves away from
  nms:`upd`endofday`endofperiod`wdbreloadhandler;
  fs:(.z.m.upd;endofday;endofperiod;handler);
  publishroot'[nms;fs];
  set[`.u.end;endofday];
  / record what was published, so the NEXT install can tell "someone else took this name" from "the
  / upd config key changed". written as ONE dict rather than amended per name
  .z.m.rootinstalled:nms!fs;
  };

dropifours:{[nm]
  / internal - delete a root name only if it still holds what .z.m.rootinstalled says WE most recently
  / put there - the same source of truth publishroot compares against, rather than a separately passed
  / "the function we believe is ours". that distinction matters for `upd specifically: start[] swaps
  / root upd to replayupd for the duration of the log replay and keeps rootinstalled in step with it
  / (see start), so a start that throws mid-replay leaves rootinstalled correctly pointing at replayupd
  / and this still reclaims it. comparing against a fixed .z.m.upd here (the earlier shape) could not:
  / .z.m.upd never changes during that window, so it would never match root's actual replayupd binding
  / and teardown would silently leave replayupd stuck at root forever - see wdb.md design decision 21
  if[not nm in key `.;:()];
  if[not (`. nm)~.z.m.rootinstalled nm;:()];
  ![`.;();0b;enlist nm];
  };

uninstallroot:{[]
  / internal - give back exactly what installroot (or start's temporary replay swap) most recently
  / published. only names still bound to what rootinstalled says THIS module put there are removed: a
  / later module that has taken over one of these root names owns it now, and silently deleting its
  / binding would be a worse outcome than leaving ours behind
  dropifours each `upd`endofday`endofperiod`wdbreloadhandler;
  / .u.end is read through a PROTECTED value, not as a bare .u.end. a shutdown path may call teardown
  / twice, and the second call would otherwise die on an unlogged '.u.end reading the name the first
  / call deleted
  if[endofday~@[value;`.u.end;{[e] :(::)}];![`.u;();0b;enlist`end]];
  };

/ ============================================================
/ init and teardown
/ ============================================================

requiremode:{[m;w]
  / internal - reject every mode this version does not implement, rather than silently accepting one
  / and behaving as though it were `saveandsort.
  / `save is NOT a trivial variant. wdb.q:93-94 sets sortenabled:any `sort`saveandsort in mode, so
  / `save gives sortenabled:0b, and endofday (wdb.q:218-221) then dispatches to informsortandreload
  / instead of endofdaysort - shipping (`.wdb.endofdaysort;...) to a separate `sort process over IPC
  / (wdb.q:513-525). that is the sort-worker split this version defers. accepting `save here would run
  / the sort in-process that the operator deliberately delegated elsewhere, double-sorting whenever a
  / sort process also exists - so this is a loud rejection, not a silent substitution.
  / consequence, stated in wdb.md: the shipped TorQ config/settings/wdb.q sets mode:`save and so will
  / NOT load unmodified. the fix is one line, mode:`saveandsort
  if[not m~supportedmode;
    '"di.wdb: only mode=`saveandsort and writedownmode=`default are supported in this version; ",
      "mode=`",string[m]," selects the separate sort-process architecture, which is deferred"];
  if[not w~supportedwritedownmode;
    '"di.wdb: only mode=`saveandsort and writedownmode=`default are supported in this version; ",
      "writedownmode=`",string[w]," selects a parted write-down mode, which is deferred"];
  };

init:{[deps]
  / wire the injected dependencies (log and timer - both REQUIRED, never defaulted) and this module's
  / config, then publish the root entry points. ONE dict carrying dependency and config keys side by
  / side - the call shape di.torq wires every module with.
  / e.g. wdb.init[logging.logdict,`timer`savedir`hdbdir!(timerdep;`:/data/wdb;`:/data/hdb)]
  / NB build deps as ONE multi-key dict. joining di.log's logdict to a chain of single-key dicts
  / throws 'mismatch, because both value sides are tables.
  / NB init does NO i/o and initialises NO other module. di.servers, di.subscriptions and di.dbwrite
  / are shared framework state whose lifecycle belongs to the caller (di.torq, or a test harness);
  / this module only USES them, and only from start[] onwards. see wdb.md
  if[99h<>type deps;
    '"di.wdb: deps must be a dict of injectables + config, with `log and `timer keys"];
  if[not all `log`timer in key deps;
    '"di.wdb: log and timer dependencies are required; pass `log (`info`warn`error) and `timer ",
      "(see di.log, di.timer); got: ",(", " sv string key deps)];
  if[99h<>type deps`log;
    '"di.wdb: log value must be a dict; pass `info`warn`error functions - see di.log"];
  if[not all `info`warn`error in key deps`log;
    '"di.wdb: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  if[99h<>type deps`timer;
    '"di.wdb: timer value must be a dict - see di.timer"];
  if[not `addjob in key deps`timer;
    '"di.wdb: timer dict must expose `addjob - see di.timer"];
  if[99h<>type deps[`timer]`addjob;
    '"di.wdb: timer`addjob must be a variant dict - see di.timer addjob.custom/default/simple"];
  if[not `custom in key deps[`timer]`addjob;
    '"di.wdb: timer`addjob must expose the `custom variant [id;func;params;period;mode;opts]"];
  / deletejobs is checked for presence AND callability. a dict-valued dep returns a null-shaped DICT
  / for a missing key rather than erroring, and teardown's @[.z.m.timer[`deletejobs];ids;handler] is
  / protected-apply ONLY when the first argument is a function - with a dict there, q reads the whole
  / expression as three-argument AMEND, upserts the ids into a throwaway dict, discards the result and
  / carries on having deleted nothing and logged nothing
  if[not iscallable deps[`timer]`deletejobs;
    '"di.wdb: timer`deletejobs must be a function [ids]; a missing or non-callable value fails ",
      "SILENTLY at teardown rather than loudly here - see di.timer"];
  / resolve config, then COERCE AND VALIDATE EVERY KEY INTO A LOCAL before a single write lands, so a
  / rejected re-init cannot leave the module half-configured
  d:configdefaults[];
  c:cfg[deps;d];
  m:assym[`mode;c`mode];
  w:assym[`writedownmode;c`writedownmode];
  requiremode[m;w];
  tptypes:aslist assym[`tickerplanttypes;c`tickerplanttypes];
  if[0=count tptypes;
    '"di.wdb: tickerplanttypes must name at least one proctype - an empty list resolves to `, ",
      "which di.servers matches against every connected process"];
  nr:aslong[`numrows;c`numrows];
  nt:astabdict[`numtab;c`numtab];
  / replaynumrows/replaynumtab fall back to the RESOLVED numrows/numtab, not to their static defaults,
  / so a caller who sets numrows and leaves replaynumrows alone gets their value on both paths.
  / legacy leaves both entirely undefined except via config layering - config/settings/wdb.q:17-18 is
  / their only definition anywhere in the codebase - which is an inconsistency, not a design
  rnr:$[`replaynumrows in key deps;aslong[`replaynumrows;deps`replaynumrows];nr];
  rnt:$[`replaynumtab in key deps;astabdict[`replaynumtab;deps`replaynumtab];nt];
  ptype:assym[`partitiontype;c`partitiontype];
  updf:c`upd;
  if[not iscallable updf;
    '"di.wdb: upd must be a binary function taking (tablename;data), and not null"];
  if[99h<>type c`savedownmanipulation;
    '"di.wdb: savedownmanipulation must be a dict of tablename!function"];
  if[not iscallable c`postreplay;
    '"di.wdb: postreplay must be a binary function taking (hdbdir;partition)"];
  hdbtypes:aslist assym[`hdbtypes;c`hdbtypes];
  rdbtypes:aslist assym[`rdbtypes;c`rdbtypes];
  gwtypes:aslist assym[`gatewaytypes;c`gatewaytypes];
  ignore:aslist assym[`ignorelist;c`ignorelist];
  rorder:aslist assym[`reloadorder;c`reloadorder];
  savedir:normpath ashsym[`savedir;c`savedir];
  hdbroot:normpath ashsym[`hdbdir;c`hdbdir];
  / the working directory must NOT be the hdb root. it is never a valid configuration - the whole
  / point of savedir is a staging area the eod move drains into the hdb - and the failure it causes
  / is quiet and recurring rather than loud: savetables writes straight into the hdb, then movetohdb
  / finds every table present in BOTH source and destination and aborts the move, logging
  / "present in both" on EVERY end of day for the life of the process (measured). the data happens
  / to land in the right place, so nothing looks broken until someone reads the log
  if[savedir~hdbroot;
    '"di.wdb: savedir and hdbdir must be different directories; both are ",(string savedir),
      " - savedir is the intraday staging area that the end of day move drains into hdbdir"];
  stimer:astimespan[`settimer;c`settimer];
  eodwait:astimespan[`eodwaittime;c`eodwaittime];
  sleepintv:aslong[`tpconnsleepintv;c`tpconnsleepintv];
  if[0>=sleepintv;
    '"di.wdb: tpconnsleepintv must be a positive whole number of seconds; got: ",.Q.s1 c`tpconnsleepintv];
  cycles:aslong[`tpcheckcycles;c`tpcheckcycles];
  imm:asbool[`immediate;c`immediate];
  sch:asbool[`schema;c`schema];
  rep:asbool[`replay;c`replay];
  prel:asbool[`permitreload;c`permitreload];
  gcflag:asbool[`gc;c`gc];
  / is this the FIRST init in this process? read it BEFORE any write, because initialised[] probes
  / hdbdir and this must reflect the state on entry
  fresh:not initialised[];
  .z.m.loginfo:(deps`log)`info;
  .z.m.logwarn:(deps`log)`warn;
  .z.m.logerr:(deps`log)`error;
  .z.m.timer:deps`timer;
  / cp is OPTIONAL. di.timer exports setcp but no cp GETTER, so requiring it would reject every
  / caller wiring a timer dep from di.timer's own exports. it is honoured when supplied - that is
  / legacy's .proc.cp[] simulated-clock hook - and falls back to .z.p otherwise
  .z.m.cp:$[`cp in key deps`timer;deps[`timer]`cp;{[] .z.p}];
  if[not iscallable .z.m.cp;
    '"di.wdb: timer`cp, when supplied, must be a niladic function returning a timestamp"];
  / handlers is accepted but never required and never validated: v1 assigns no .z.* handler at all.
  / stored rather than dropped so a caller passing one is not silently ignored
  .z.m.handlers:$[`handlers in key deps;deps`handlers;()!()];
  / one explicit write per config key - a dynamic loop over the dict would hide a missing key
  / completely, because a bare read of an unwritten name resolves silently to nothing
  .z.m.mode:m;
  .z.m.writedownmode:w;
  .z.m.tickerplanttypes:tptypes;
  .z.m.hdbtypes:hdbtypes;
  .z.m.rdbtypes:rdbtypes;
  .z.m.gatewaytypes:gwtypes;
  .z.m.ignorelist:ignore;
  .z.m.subtabs:assym[`subtabs;c`subtabs];
  .z.m.subsyms:assym[`subsyms;c`subsyms];
  .z.m.schema:sch;
  .z.m.replay:rep;
  .z.m.savedir:savedir;
  .z.m.sortcsv:c`sortcsv;
  .z.m.numrows:nr;
  .z.m.numtab:nt;
  .z.m.replaynumrows:rnr;
  .z.m.replaynumtab:rnt;
  .z.m.partitiontype:ptype;
  .z.m.immediate:imm;
  .z.m.settimer:stimer;
  .z.m.reloadorder:rorder;
  .z.m.permitreload:prel;
  .z.m.gc:gcflag;
  .z.m.eodwaittime:eodwait;
  .z.m.tpconnsleepintv:sleepintv;
  .z.m.tpcheckcycles:cycles;
  .z.m.upd:updf;
  .z.m.savedownmanipulation:c`savedownmanipulation;
  .z.m.postreplay:c`postreplay;
  / hdbdir is written LAST of the config keys because initialised[] probes it
  .z.m.hdbdir:hdbroot;
  / RUNTIME state is seeded only on a FRESH init. a re-init - di.torq re-applying config, a config
  / reload, a second wiring - must not wipe a live wdb's partition, subscription or in-flight reload
  if[fresh;
    .z.m.currentpartition:0Nd;
    .z.m.subtables:`$();
    .z.m.tplogdate:0Nd;
    .z.m.tabsizes:tabsizesschema;
    .z.m.reloadsummary:reloadsummaryschema;
    .z.m.reloadcomplete:0b;
    .z.m.countreload:0;
    .z.m.timeouttime:0Wp;
    / what installroot last published at root, keyed by name. seeded here rather than at module load
    / because publishroot reads it on the FIRST install, before installroot has written it
    .z.m.rootinstalled:(`$())!();
    .z.m.started:0b];
  installroot[];
  .z.m.loginfo[`init;"di.wdb initialised - mode ",(string .z.m.mode),", writedownmode ",
    (string .z.m.writedownmode),", savedir ",(string .z.m.savedir),", hdbdir ",string .z.m.hdbdir];
  };

teardown:{[]
  / release everything init and start installed process-wide: the root entry points and the timer
  / jobs. module state is deliberately LEFT INTACT so a shutdown path can still inspect the partition
  / and the table sizes; only the process-global bindings are withdrawn
  requireinit[`teardown];
  uninstallroot[];
  / deleting a job that was never scheduled is a no-op in di.timer (it is a delete-where over the jobs
  / table), so neither id has to exist; both go in ONE call for that reason.
  / NB this @[...] is protected-apply ONLY because init guarantees `deletejobs is present and callable
  @[.z.m.timer[`deletejobs];`wdbsavetodisk`wdbeodflush;
    {[e] .z.m.logwarn[`teardown;"could not delete the wdb timer jobs: ",e]}];
  .z.m.started:0b;
  .z.m.loginfo[`teardown;"di.wdb root entry points and timer jobs removed"];
  };

/ ============================================================
/ partitioning and row limits
/ ============================================================

getpartition:{[]
  / the partition value data is currently written under - TorQ writedown.q:19-23. the value set by
  / fixpartition or by the last eod roll, or today cast to partitiontype if neither has run.
  / NB legacy sources today from .proc.cd[], its simulated-clock hook. that is dropped rather than
  / ported without the simulation machinery that gives it meaning, exactly as di.rdb dropped .proc.cp
  :$[null .z.m.currentpartition;(`date^.z.m.partitiontype)$.z.D;.z.m.currentpartition];
  };

maxrows:{[t]
  / the live row limit for one table - TorQ writedown.q:13. a table with no numtab entry gets numrows
  :.z.m.numrows^.z.m.numtab t;
  };

replaymaxrows:{[t]
  / the row limit applied during the log replay - TorQ writedown.q:14
  :.z.m.replaynumrows^.z.m.replaynumtab t;
  };

tablelist:{[]
  / the tables this wdb deals with, largest-on-disk first - TorQ wdb.q:115-116. the ordering is
  / legacy's: flushing the biggest tables first frees the most memory soonest.
  / tabsizes is hoisted into a local because a module-level name cannot be resolved in a q-sql clause
  ts:.z.m.tabsizes;
  sorted:exec tablename from `bytes xdesc ts;
  live:tables[`.];
  / INTERSECT the tabsizes ordering with what is actually at root before unioning. tabsizes is
  / bookkeeping that outlives the tables it describes: a table written down earlier and since dropped
  / from root stays in it, and legacy's plain `sorted union tables[`.]` then hands savetables a name
  / whose `value t` throws '<tablename> - aborting the ENTIRE end of day on a stale bookkeeping row,
  / with the day's other tables unwritten (measured). tabsizes drives the ORDER here, not membership
  :((sorted inter live) union live) except .z.m.ignorelist;
  };

/ ============================================================
/ the intraday write-down path
/ ============================================================

rungc:{[]
  / run a garbage collection and log what it freed - the port of TorQ's .gc.run (dbwriteutils.q:93).
  / di.dbwrite defines gc and memstats but does NOT export them (verified against its export dict on
  / every branch), so this module runs its own rather than reaching into another module's internals
  .z.m.loginfo[`garbagecollect;"starting garbage collect"];
  r:.Q.gc[];
  .z.m.loginfo[`garbagecollect;"garbage collection returned ",(string `long$r%1048576),"MB"];
  };

manipulate:{[t;x]
  / apply the configured save-down manipulation for this table, falling back to the UNMODIFIED data on
  / failure - the port of TorQ's .save.manipulate (dbwriteutils.q:75-78).
  / the fallback is the point, not an oversight: a manipulation that throws must not lose the day's
  / data, so the error is logged and the original rows are saved. see wdb.md decision 1
  if[not t in key .z.m.savedownmanipulation;:x];
  :@[.z.m.savedownmanipulation t;x;
     {[t;x;e] .z.m.logerr[`manipulate;"save down manipulation failed for ",(string t),": ",e];:x}[t;x]];
  };

savetables:{[dir;pt;forcesave;t]
  / write one root table to its working-directory partition and clear it - the default-mode writedown
  / from TorQ code/wdb/writedown.q:27-48. returns 1b if it wrote, 0b if the table was under its limit.
  / NB this deliberately does NOT go through di.dbwrite.savedown. savedown enumerates with
  / .Q.en[dir;...] and writes under .Q.par[dir;...] - the SAME dir - but the wdb must enumerate
  / against the HDB sym file while writing to a separate working directory, so the write is
  / hand-rolled here. see wdb.md decision 3
  arows:count value t;
  if[not forcesave or maxrows[t]<arows;:0b];
  .z.m.loginfo[`rowcheck;"the ",(string t)," table consists of ",(string arows)," rows"];
  .z.m.loginfo[`save;"saving ",(string t)," data to partition ",string pt];
  path:` sv .Q.par[dir;pt;t],`;
  / the WHOLE save pipeline - the manipulation, the unkey, the enumeration and the write - runs
  / inside ONE protected apply, and the enumerated data comes back out for tabsizes.
  / anything evaluated as an ARGUMENT to @[...]/.[...] instead throws BEFORE the handler is reached
  / and escapes the logger with a bare error naming neither the module nor the table. two separate
  / defects of exactly that shape lived here (both measured):
  /   .Q.en outside the guard - an unwritable hdb root gave "/path/sym. OS reports: ..."
  /   0!manipulate[...] outside the guard - a savedownmanipulation returning a non-table gave 'type
  / legacy writes both as arguments. keeping the pipeline in one guarded block is what makes the
  / raiseerror contract hold for every way a save can fail
  r:.[{[t;h;p] d:0!manipulate[t;value t]; p upsert .Q.en[h;d]; :d};(t;.z.m.hdbdir;path);
     {[t;e] raiseerror[`savetables;"failed to save ",(string t)," to disk: ",e]}[t]];
  .z.m.loginfo[`track;"appending table details to tabsizes"];
  .z.m.tabsizes:.z.m.tabsizes+([tablename:enlist t]rowcount:enlist arows;bytes:enlist -22!r);
  .z.m.loginfo[`delete;"deleting ",(string t)," data from in-memory table"];
  @[`.;t;0#];
  if[.z.m.gc;rungc[]];
  :1b;
  };

savetodisk:{[]
  / the body of the periodic `wdbsavetodisk timer job - TorQ wdb.q:190-193.
  / NB legacy pairs the filldb call with notifyidbs. notifyidbs is NOT ported (no IDB tier in v1) but
  / filldb is kept: it is real default-mode on-disk behaviour that leaves the working partition
  / complete, and it is cheap. see wdb.md decision 6
  pt:getpartition[];
  changes:savetables[.z.m.savedir;pt;.z.m.immediate;] each tablelist[];
  if[any changes;filldb pt];
  };

starttimer:{[]
  / schedule savetodisk to run every settimer for the life of the process - TorQ wdb.q:528-536
  / (.timer.repeat) on the injected timer. mode 1 measures the period from the previously SCHEDULED
  / start, which is what .timer.repeat did.
  / disableonfail 0b: a write-down job that switches itself off after one bad cycle would silently
  / stop persisting data for the rest of the day, which is the failure this process exists to prevent
  / NB period is a RAW COUNT OF SECONDS, not a timespan - verified against di.timer's own addjob.custom
  / (`int$period on the way in, then nextstart:(0D00:00:01*period)+... in upd.start/nextstart[1h]), so
  / dividing settimer by one second here is the correct conversion, not an approximation. a timespan
  / passed instead of that raw count would be silently reinterpreted as a count of NANOSECONDS - see
  / wdb.md design decision 22
  p:`long$.z.m.settimer%0D00:00:01;
  if[0>=p;
    raiseerror[`starttimer;"settimer must be a positive interval; got: ",string .z.m.settimer]];
  @[{.z.m.timer[`addjob][`custom][`wdbsavetodisk;savetodisk;();x;1;`maxruns`disableonfail!(0Wi;0b)]};
    p;
    {[e] .z.m.logerr[`starttimer;"could not schedule the save to disk job: ",e]}];
  .z.m.loginfo[`init;"the timer has been set to ",string .z.m.settimer];
  };

/ ============================================================
/ startup - the i/o phase
/ ============================================================

clearwdbdata:{[]
  / remove any data already sitting in the working partition before the log replay - TorQ
  / wdb.q:603-613. replaying on top of a previous run's partition would double every row
  wdbpart:.Q.par[.z.m.savedir;getpartition[];`];
  if[()~key wdbpart;
    .z.m.loginfo[`deletewdbdata;"no directory found at ",1_string wdbpart];
    :()];
  d:1_string wdbpart;
  .z.m.loginfo[`deletewdbdata;"removing wdb data (",d,") prior to log replay"];
  / an error here can happen on windows if another process holds the folder open
  @[osutil[`deldir];d;
    {[d;e] raiseerror[`clearwdbdata;"failed to delete existing wdb data at ",d,": ",e]}[d]];
  .z.m.loginfo[`deletewdbdata;"finished removing wdb data prior to log replay"];
  };

waitone:{[budget;pollms;types;s]
  / internal - ONE step of waitfortp's fold. s is (nextindex;foundtype): once a type has been found,
  / or the list is exhausted, every later step is a no-op, which is how the fold short circuits
  / without a do/while
  if[not null s 1;:s];
  if[s[0]>=count types;:s];
  t:types s 0;
  :$[servers.waitfortype[t;budget;pollms];(1+s 0;t);(1+s 0;`)];
  };

tptimeout:{[]
  / internal - the total millisecond wait budget waitfortp hands di.servers, derived from legacy's
  / tpcheckcycles x tpconnsleepintv retry loop. split out from waitfortp so the clamp below is
  / unit-testable without actually blocking.
  / NB tpcheckcycles 0W - legacy's DEFAULT, meaning retry forever - cannot simply be multiplied out:
  / the product overflows a long and comes back NEGATIVE, which would make the wait return
  / immediately and the wdb give up on a tickerplant that was merely slow to start. the cycle count
  / is capped against the largest budget that fits in an int millisecond count first
  pollms:1000*.z.m.tpconnsleepintv;
  maxcycles:2147483647 div 1|pollms;
  :$[.z.m.tpcheckcycles>=maxcycles;2147483647;.z.m.tpcheckcycles*pollms];
  };

waitfortp:{[]
  / block until one of the configured tickerplant proctypes connects, and return it, or ` if none did
  / - TorQ origstartup.q:14 (.servers.startupdepcycles) on di.servers' waitfortype.
  / legacy loops tpcheckcycles times sleeping tpconnsleepintv seconds; waitfortype takes a millisecond
  / budget, so the two config keys collapse into pollms and tptimeout[].
  / di.servers.waitfortype takes a SINGLE proctype, so the budget is split across the configured types
  / rather than granted to each in full: three types under a 30s budget must still return within 30s.
  / with one configured type - overwhelmingly the common case - this is exactly waitfortype
  pollms:1000*.z.m.tpconnsleepintv;
  types:.z.m.tickerplanttypes;
  :last (count types) waitone[1|tptimeout[] div count types;pollms;types]/(0;`);
  };

fixpartition:{[subto]
  / the tickerplant log may be for a different date than the partition already being written to. move
  / any data written under the wrong one - TorQ wdb.q:550-565
  tplogdate:subto`tplogdate;
  orig:getpartition[];
  if[tplogdate~orig;:()];
  .z.m.loginfo[`fixpartition;"current partition date does not match the tickerplant log date"];
  .z.m.currentpartition:tplogdate;
  p1:osutil.topath -1_string .Q.par[.z.m.savedir;orig;`];
  p2:osutil.topath -1_string .Q.par[.z.m.savedir;tplogdate;`];
  if[()~key hsym`$p1;:()];
  / clear the DESTINATION first - currentpartition is already tplogdate, so this targets p2
  clearwdbdata[];
  .z.m.loginfo[`fixpartition;"moving data from partition ",p1," to partition ",p2];
  .[osutil[`mv];(p1;p2);
    {[a;b;e] .z.m.logerr[`fixpartition;"failed to move wdb partition ",a," to ",b,": ",e]}[p1;p2]];
  };

inittable:{[t;pt]
  / write table t's empty schema into the partition if it is not already there - TorQ wdb.q:582-585
  tabledir:` sv .Q.par[.z.m.savedir;pt;t],`;
  if[()~key tabledir;tabledir set .Q.en[.z.m.hdbdir;0#value t]];
  };

filldb:{[pt]
  / fill any gaps in the partition so it is a complete, queryable database - TorQ wdb.q:576-579
  .Q.chk .Q.par[.z.m.savedir;pt;`];
  };

initmissingtables:{[pt]
  / make sure the partition holds every table, empty where it has no data - TorQ wdb.q:570-574.
  / legacy reaches this at eod through idbreload; the IDB notification half is dropped with the IDB
  / tier but the priming is kept - it is what leaves a partition complete rather than ragged
  .z.m.loginfo[`fixpartition;"adding missing tables (empty) to partition ",string pt];
  inittable[;pt] each tablelist[];
  filldb[pt];
  };

replaymaxrowcheck:{[t;lmt]
  / flush one table to disk if it has passed its REPLAY row limit - TorQ wdb.q:595-599.
  / NB forcesave is 1b where legacy passes 0b. legacy's savetables then re-checks the table against
  / the LIVE maxrows and can silently REFUSE the flush this function has already logged - "flushing
  / table to disk..." followed by nothing. that only bites when replaynumrows is below numrows, which
  / is an odd but legal configuration, and it is exactly the kind of silent gap this project makes
  / explicit rather than inherits: the decision to flush was taken here, against the replay limit, so
  / re-taking it against a different threshold is incoherent. equivalent to legacy in every
  / configuration where replaynumrows >= numrows, which is the normal one. see wdb.md decision 8
  rpc:count value t;
  if[rpc<=lmt;:()];
  .z.m.loginfo[`replayupd;"row limit (",(string lmt),") exceeded for ",(string t),
    ". table count is: ",(string rpc),". flushing table to disk..."];
  savetables[.z.m.savedir;getpartition[];1b;t];
  };

replaysweep:{[]
  / after the replay, re-check every subscribed table against its NORMAL row limit and flush any that
  / are over - TorQ origstartup.q:19-23. the replay ran under the (usually larger) replay limits, so a
  / table can be left holding more than the live limit allows. gated exactly as legacy gates it: a
  / no-op when the replay limits match the live ones
  if[(.z.m.numtab~.z.m.replaynumtab) and .z.m.numrows=.z.m.replaynumrows;:()];
  t:.z.m.subtables;
  if[0=count t;:()];
  replaymaxrowcheck'[t;maxrows each t];
  };

subscribe:{[]
  / find a tickerplant and subscribe to it - TorQ wdb.q:539-547
  tpt:waitfortp[];
  if[null tpt;
    raiseerror[`subscribe;"no ",(", " sv string .z.m.tickerplanttypes)," connection within the ",
      "configured tpconnsleepintv/tpcheckcycles budget - cannot start the wdb"]];
  tph:servers.gethandlebytype[tpt;defaultselection];
  if[null tph;
    raiseerror[`subscribe;"di.servers reported a ",(string tpt)," connection but returned no handle"]];
  .z.m.loginfo[`subscribe;"tickerplant found - subscribing to ",string tpt];
  subto:subscriptions.subscribe[tph;.z.m.subtabs;.z.m.subsyms;.z.m.schema;.z.m.replay];
  .z.m.subtables:(),subto`subtables;
  .z.m.tplogdate:subto`tplogdate;
  .z.m.loginfo[`subscribe;"subscribed to ",(", " sv string .z.m.subtables),"; tickerplant log date ",
    string .z.m.tplogdate];
  / check the tp log date against the current partition and correct it if necessary
  fixpartition[subto];
  };

start:{[]
  / connect to the tickerplant, subscribe, replay the day's log and start the write-down timer. split
  / out of init deliberately: init is pure configuration and can be unit-tested with no sockets and no
  / other module initialised, whereas everything here needs di.servers, di.subscriptions and
  / di.dbwrite already wired by the caller. TorQ makes the same split - .wdb.startup[] is its own
  / function, called at the bottom of wdb.q rather than inline with the config
  requireinit[`start];
  / RE-PUBLISH the root entry points. init installs them, but teardown removes them and a caller may
  / legitimately tear down and start again without re-initialising
  installroot[];
  if[.z.m.started;
    .z.m.loginfo[`start;"start has already completed - nothing to do"];
    :()];
  / the sort/attribute config di.dbwrite applies at eod - TorQ loads the same csv (wdb.q:657 via
  / getsortparams). only the csv LOAD is ported; getsortparams' other half is a parted-writedown
  / business rule, unreachable once writedownmode is validated to `default
  if[not .z.m.sortcsv~`;
    @[dbwrite[`readcsv];.z.m.sortcsv;
      {[e] .z.m.logwarn[`start;"could not read sortcsv - eod sorting falls back to di.dbwrite's ",
        "defaults: ",e]}]];
  / clear any stale data in the working partition BEFORE the replay - TorQ wdb.q:674
  clearwdbdata[];
  / the replay drives the ROOT upd, so it must be the flushing one before subscribe runs - TorQ
  / wdb.q:672 sets root upd to replayupd, then origstartup.q:25 swaps it back after.
  / NB rootinstalled is updated in lockstep with EACH swap, not just at installroot - dropifours reads
  / rootinstalled as the single source of truth for "what did we put at this name", so if anything
  / below throws before the swap-back, teardown must see replayupd there, not the pre-replay value
  @[`.;`upd;:;replayupd];
  .z.m.rootinstalled[`upd]:replayupd;
  servers.startup[];
  subscribe[];
  initmissingtables[getpartition[]];
  replaysweep[];
  / swap the root upd back to the live one now the replay is done - origstartup.q:25
  @[`.;`upd;:;.z.m.upd];
  .z.m.rootinstalled[`upd]:.z.m.upd;
  starttimer[];
  / started is set LAST: everything above can throw, and setting it early would leave a half-started
  / wdb that status[] reported as healthy
  .z.m.started:1b;
  .z.m.loginfo[`start;"di.wdb started - writing to ",string .z.m.savedir];
  };

/ ============================================================
/ end of day
/ ============================================================

endofdaysave:{[dir;pt;tabs]
  / flush every remaining row to disk - TorQ wdb.q:234-239
  .z.m.loginfo[`save;"saving the ",(", " sv string tabs)," table(s) to disk"];
  savetables[dir;pt;1b;] each tabs;
  .z.m.loginfo[`savefinish;"finished saving data to disk"];
  };

reloadsymfile:{[symfilepath]
  / reload the hdb sym file so enumerations written this session are visible - TorQ wdb.q:307-310.
  / a MISSING sym file is NOT an error. .Q.en creates it on the first write, so an hdb that has never
  / been written to legitimately has none - and legacy's unguarded `load` then logs a failure at
  / ERROR level on every clean no-data roll, which is exactly the kind of noise that teaches an
  / operator to ignore the log
  if[()~key symfilepath;
    .z.m.loginfo[`sort;"no sym file at ",(string symfilepath)," yet - nothing to reload"];
    :()];
  .z.m.loginfo[`sort;"reloading the sym file from: ",string symfilepath];
  @[load;symfilepath;{[e] .z.m.logerr[`sort;"failed to reload sym file: ",e]}];
  };

sortone:{[dir;pt;t]
  / internal - sort and attribute ONE table's partition directory through di.dbwrite, then collect.
  / di.dbwrite drives both the sort column order and the p/s/g/u attributes off the config loaded by
  / readcsv, falling back to its own defaults when none was loaded.
  / PROTECTED, per table. by the time this runs the day's rows are already on disk, so a sort failure
  / must not abandon the remaining tables or strand the partition in the working directory - an
  / unsorted partition that reached the hdb is recoverable (re-sort in place), one that never moved is
  / not. di.dbwrite takes the same view internally, logging and continuing per column and per
  / directory rather than rethrowing.
  / the case this actually catches is narrower than it first looks, and the distinction matters.
  / di.dbwrite.init SEEDS .z.m.sortconfig:(::), and sort explicitly tests (::)~.z.m.sortconfig and
  / falls through to its own defaultparams - so an INITIALISED but unconfigured di.dbwrite sorts
  / fine and never throws (measured, both branches). the only reachable failure is a caller that
  / never called di.dbwrite.init AT ALL, where the name does not exist and sort dies on an
  / undefined-name error - and then every table fails, not one.
  / di.wdb deliberately does NOT call di.dbwrite.init itself to close that hole: init RESETS
  / sortconfig to (::), so doing so from here would silently WIPE a sort config the caller had
  / already loaded with readcsv and downgrade every table to sort-by-time (measured). the caller
  / owns that lifecycle - see wdb.md, "who initialises what"
  .[dbwrite[`sort];(t;.Q.par[dir;pt;t]);
    {[t;e] .z.m.logerr[`sort;"failed to sort the ",(string t)," partition: ",e,
      " - the data is on disk but unsorted. is di.dbwrite initialised?"]}[t]];
  if[.z.m.gc;rungc[]];
  };

movewhole:{[dw;hw]
  / internal - the hdb has no partition for this date, so the whole working directory becomes it
  .[osutil[`mv];(dw;hw);
    {[a;b;e] raiseerror[`movetohdb;"failed to move data from wdb ",a," to hdb directory ",b,": ",e]}[dw;hw]];
  .z.m.loginfo[`mvtohdb;"moved ",dw," to ",hw];
  };

movetable:{[hw;src]
  / internal - move ONE table directory into an hdb partition that already exists
  b:`$last "/" vs src;
  .[osutil[`mv];(src;hw);
    {[t;h;e] .z.m.logerr[`mvtohdb;"table ",(string t)," failed to copy to ",h," with error: ",e]}[b;hw]];
  .z.m.loginfo[`mvtohdb;"table ",(string b)," has been successfully moved to ",hw];
  };

movetohdb:{[dw;hw;pt]
  / move the day's working partition into the hdb - TorQ wdb.q:293-305. three cases: the hdb has no
  / partition for this date (move the whole directory), it has one but no table clashes (move each
  / table in turn), or there is a clash (abort rather than corrupt the hdb).
  / NB legacy locates the hdb root as `-10 _ hw`, dropping exactly the ten characters of a DATE
  / partition, which silently breaks for `month or `year partitiontypes. the root is taken from config
  / here instead. see wdb.md decision 5
  / NOTHING WAS WRITTEN THIS CYCLE - a roll with no tables, or every table on the ignorelist, leaves
  / no working partition at all. attempting the move anyway makes di.os shell out to a doomed `mv`,
  / whose OS error text lands on STDERR as raw output before this module ever sees it (measured:
  / "mv: cannot stat '.../2026.02.01': No such file or directory" on an otherwise clean roll). guard
  / it here rather than let a benign empty end of day print shell noise in a client's log
  if[()~key hsym`$dw;
    .z.m.loginfo[`mvtohdb;"no working partition at ",dw," - nothing to move to the hdb"];
    :()];
  existing:@[{key hsym x};.z.m.hdbdir;{[e] :`symbol$()}];
  if[not (`$string pt) in existing;:movewhole[dw;hw]];
  dtabs:@[{key hsym`$x};dw;{[e] :`symbol$()}];
  htabs:@[{key hsym`$x};hw;{[e] :`symbol$()}];
  clash:dtabs inter htabs;
  if[count clash;
    raiseerror[`movetohdb;"table(s) ",(", " sv string clash)," are present in both ",dw," and ",hw,
      " - operation aborted to avoid corrupting the hdb"]];
  movetable[hw;] each dw,/:"/",/:string dtabs;
  / drop the now-empty working partition directory
  if[0=count @[{key hsym`$x};dw;{[e] :`symbol$()}];
    @[osutil[`deldir];dw;{[d;e] .z.m.logerr[`mvtohdb;"failed to delete folder ",d," with error: ",e]}[dw]]];
  };

runpostreplay:{[dir;pt]
  / the user-defined post-eod hook - TorQ's .save.postreplay (dbwriteutils.q:82), invoked after every
  / table is on disk (wdb.q:333). protected: a broken hook must not abort a roll whose data is already
  / safely written
  .[.z.m.postreplay;(dir;pt);
    {[e] .z.m.logerr[`postreplay;"post replay function failed: ",e]}];
  };

endofdaysortdate:{[dir;pt;tabs]
  / the default-mode end of day: sort the day's partitions, move them into the hdb, run the post-eod
  / hook and trigger the reloads - TorQ wdb.q:312-337.
  / the .z.pd sort-worker fan-out is deferred, so this is always legacy's "sorting on main sort" path
  .z.m.loginfo[`sort;"starting to sort data"];
  reloadsymfile .Q.dd[.z.m.hdbdir;`sym];
  sortone[dir;pt;] each tabs;
  .z.m.loginfo[`sort;"finished sorting data"];
  dw:osutil.topath -1_string .Q.par[dir;pt;`];
  hw:osutil.topath -1_string .Q.par[.z.m.hdbdir;pt;`];
  .z.m.loginfo[`mvtohdb;"moving partition from the temp wdb ",dw," directory to the hdb ",hw];
  .[movetohdb;(dw;hw;pt);{[e] .z.m.logerr[`mvtohdb;"function movetohdb failed with error: ",e]}];
  runpostreplay[.z.m.hdbdir;pt];
  if[.z.m.permitreload;doreload[pt]];
  };

endofday:{[pt]
  / the tickerplant's end of day broadcast, published at root (and as .u.end) by init.
  / UNARY, where TorQ's is endofday[pt;processdata] - legacy never references processdata anywhere in
  / the function body (wdb.q:204-232) and the shipped .u.end alias passes ()!() for it, so the second
  / parameter carries no information. di.pubsub.callendofday broadcasts (`endofday;d), one argument,
  / so a binary function here would silently become a PROJECTION and the roll would never happen
  requireinit[`endofday];
  .z.m.loginfo[`eod;"end of day message received - ",string pt];
  / capture the table list BEFORE the save empties them, as legacy does
  tabs:tablelist[];
  endofdaysave[.z.m.savedir;pt;tabs];
  endofdaysortdate[.z.m.savedir;pt;tabs];
  .z.m.loginfo[`eod;"deleting data from tabsizes"];
  .z.m.tabsizes:0#.z.m.tabsizes;
  .z.m.currentpartition:pt+1;
  / prime the NEW partition with every table schema. legacy reaches this through idbreload
  / (wdb.q:465, 643-652); the notifyidbs half is dropped with the IDB tier, the priming is kept
  initmissingtables[.z.m.currentpartition];
  .z.m.loginfo[`eod;"end of day is now complete"];
  };

endofperiod:{[currp;nextp;data]
  / the tickerplant's intraday period roll, published at root by init - the port of
  / code/wdb/writedown.q:52. log-only, as legacy is: a wdb has nothing to do at a period boundary, but
  / the message has to land somewhere or it surfaces as an unhandled async message.
  / TERNARY, matching its producer: di.pubsub.callendofperiod broadcasts
  / (`endofperiod;currentperiod;nextperiod;data), and its own source comment names this very function
  / as one of the two subscribers it was made ternary for
  requireinit[`endofperiod];
  .z.m.loginfo[`endofperiod;"received endofperiod. currentperiod, nextperiod and data are ",
    (string currp),", ",(string nextp),", ",.Q.s1 data];
  };

/ ============================================================
/ reload - telling the rdbs and hdbs the day has landed
/ ============================================================

remotereload:{[d;ptype]
  / the lambda a reloading process RUNS. it is serialised and sent by asyncreload, so everything it
  / touches must resolve on the REMOTE - hence the explicit root index for reload, and the plain
  / symbol `wdbreloadhandler naming the callback in OUR root. TorQ wdb.q:479-480.
  / NB the reload call is PARENTHESISED: (`. `reload) x. legacy writes `. `reload x, which is a
  / DIFFERENT expression - it evaluates `reload x first (which does apply the remote's reload) and
  / then indexes the root dictionary by that result, yielding (::;::) instead of the reload's return
  / value (measured). the reload still RUNS either way, and a throw still propagates to the @[...]
  / below, so legacy is not broken here - but r's second element is then a null rather than the
  / result the expression reads as returning. parenthesised so the value is what the code says it is
  r:@[{(1b;(`. `reload) x)};d;{[e] :(0b;e)}];
  (neg .z.w)(`wdbreloadhandler;
    (ptype;first r;$[first r;`$"reloaded successfully";`$"reload failed with error ",last r]));
  (neg .z.w)[];
  };

asyncreload:{[h;d;ptype]
  / internal - fire the reload without waiting, and let wdbreloadhandler collect the reply.
  / NB what goes on the wire is the TRIPLE (remotereload;d;ptype) - the function VALUE followed by
  / its arguments, which the remote's default .z.ps applies as remotereload[d;ptype]. writing
  / remotereload[d;ptype] here instead would CALL it in this process, against our own root reload and
  / our own .z.w, and send the result rather than the work. legacy sends the same shape
  / (reloadfunc;d;ptype) through its sendfunc (wdb.q:476,486)
  .[{[m;hh] neg[hh] m;}; ((remotereload;d;ptype);h);
    {[p;e] .z.m.logerr[`reloadproc;"failed to reload the ",(string p),": ",e]}[ptype]];
  };

syncreload:{[h;d;ptype]
  / internal - the eodwaittime 0 path: reload synchronously and log the outcome - TorQ wdb.q:482-483.
  / the (function;arg) pair is evaluated on the REMOTE, so the same parenthesised root-index applies
  r:@[h;({(1b;(`. `reload) x)};d);
      {[p;e] .z.m.logerr[`reloadproc;"failed to reload the ",(string p),". the error was: ",e];:(0b;e)}[ptype]];
  .z.m.loginfo[`reloadproc;"the ",(string ptype)," ",
    $[first r;"successfully reloaded";"failed to reload with error ",.Q.s1 last r]];
  };

reloadproc:{[h;d;ptype]
  / send the reload call to one process - TorQ wdb.q:471-489
  .z.m.loginfo[`reloadproc;"sending reload call to ",string ptype];
  $[.z.m.eodwaittime>0;asyncreload[h;d;ptype];syncreload[h;d;ptype]];
  };

getprocs:{[t;pt]
  / find every live process of one type and send it a reload - TorQ wdb.q:492-499.
  / the di.servers read is PROTECTED: di.servers refuses every accessor until its own init has run,
  / and this sits on the eod path, which must not abort because a process wired di.wdb without wiring
  / di.servers
  hs:@[{[x] :exec w from servers.getservers[x]};t;
       {[p;e] .z.m.logwarn[`connection;"could not read the server list for ",(string p),": ",e];
        :`int$()}[t]];
  if[0=count hs;
    .z.m.logerr[`connection;"no connection to the ",(string t)," could be established... failed to ",
      "reload ",string t];
    :()];
  .z.m.loginfo[`connection;"connection to the ",(string t)," has been located"];
  reloadproc[;pt;t] each hs;
  };

informgateway:{[msg]
  / tell the gateways the reload has started or finished - TorQ wdb.q:502-510.
  / NB legacy wraps each send in a protected apply that RETHROWS (`'x`), so one unreachable gateway
  / aborts the whole end of day - after the data is already on disk. that rethrow is deliberately
  / dropped: a notification failure is logged and the roll continues. see wdb.md decision 7
  .z.m.loginfo[`informgateway;"sending message to gateway(s)"];
  gwt:.z.m.gatewaytypes;
  if[0=count gwt;:()];
  hs:@[{[x] :exec w from servers.getservers[x]};gwt;
       {[e] .z.m.logwarn[`informgateway;"could not read the server list: ",e];:`int$()}];
  if[0=count hs;
    .z.m.logerr[`informgateway;"can't connect to the gateway - no gateway detected"];
    :()];
  {[m;hh] .[{[m;hh] hh m;};(m;hh);
    {[e] .z.m.logerr[`informgateway;"unable to run command on gateway: ",e]}]}[msg;] each hs;
  .z.m.loginfo[`informgateway;"the message - ",(.Q.s1 msg)," was sent to the gateways"];
  };

flushend:{[]
  / release every process waiting on this roll and tell the gateways the reload is done - TorQ
  / wdb.q:257-266. idempotent: reloadcomplete makes a second call (the timer firing after every
  / process already answered) a no-op
  if[not .z.m.reloadcomplete;
    if[.z.m.eodwaittime>0;
      / the handle VECTOR, not `key` of the keyed table. legacy writes `each key reloadsummary`, but
      / `key` on a KEYED TABLE returns a TABLE, so that iterates one-column DICTS ((,`handle)!,4i)
      / rather than handles - neg[dict] is just a dict with a negated value, the send then indexes a
      / dict by "" instead of writing to a socket, and the enclosing protected apply swallows it.
      / the release silently notified NOBODY while still logging that it had (measured)
      rs:.z.m.reloadsummary;
      @[{neg[x]"";neg[x][]};;{[e] :()}] each exec handle from rs];
    / NB ONE argument - the PAIR (`reloadend;`), as legacy sends. informgateway[`reloadend;`] would
    / be a two-argument call to a unary function and throws 'rank
    informgateway (`reloadend;`);
    .z.m.loginfo[`sort;"end of day sort is now complete"];
    .z.m.reloadcomplete:1b];
  if[.z.m.gc;rungc[]];
  };

handler:{[x]
  / the reload REPLY callback, published at root as `wdbreloadhandler by installroot - TorQ
  / wdb.q:242-253. x is (proctype;ok;message).
  / it must be reachable by NAME from root: remotereload answers with an async (name;args) message
  / which the default .z.ps evaluates in root, and module functions live in private .z.m
  .z.m.reloadsummary:.z.m.reloadsummary upsert (.z.w;x 0;x 1;x 2);
  .z.m.loginfo[`reloadproc;"the ",(string x 0)," process ",string x 2];
  if[not (.z.m.cp[]>.z.m.timeouttime) or .z.m.countreload=count .z.m.reloadsummary;:()];
  .z.m.loginfo[`handler;"releasing processes"];
  rs:.z.m.reloadsummary;
  .z.m.loginfo[`reload;(string count select from rs where status)," out of ",
    (string count rs)," processes successfully reloaded"];
  flushend[];
  .z.m.reloadsummary:0#.z.m.reloadsummary;
  };

scheduleflushend:{[]
  / book the one-shot job that releases the waiting processes when the eodwaittime deadline passes -
  / TorQ wdb.q:277 (.timer.one) on the injected timer.
  / the job id is DELETED first: di.timer's addjob throws on a duplicate id, so without this the
  / second day's roll would fail to schedule its release and the reload would hang.
  / NB period is a dummy 1 here, not the settimer-derived seconds count starttimer computes - with
  / startattime set, di.timer's addjob.custom takes nextstart directly from startattime on the FIRST
  / (only) run, and maxruns:1 disables the job in upd.status before a second run could ever consult
  / period - see di.timer addjob.custom/upd.start/upd.status. verified against di.timer's own source
  .z.m.timeouttime:.z.m.cp[]+.z.m.eodwaittime;
  @[.z.m.timer[`deletejobs];`wdbeodflush;{[e] :()}];
  / if scheduling the release itself fails, nothing else will ever call flushend for this roll - every
  / process in reloadorder that already replied, and every one still waiting, would otherwise sit
  / blocked forever with no visibility into why on the wdb side. releasing immediately here is the
  / same tradeoff getprocs/informgateway already make elsewhere in this file: a failure that CAN be
  / made non-fatal to the roll is, rather than leaving callers hanging on a job that will never fire
  @[{.z.m.timer[`addjob][`custom][`wdbeodflush;flushend;();1;1;`startattime`maxruns!(x;1i)]};
    .z.m.timeouttime;
    {[e] .z.m.logerr[`scheduleflushend;"could not schedule the eod release job: ",e,
      " - releasing waiting processes immediately rather than leaving them blocked on a timeout ",
      "that will never fire"];
     flushend[]}];
  };

doreload:{[pt]
  / tell every process in reloadorder to reload, then release them once they have all replied or the
  / eodwaittime deadline passes - TorQ wdb.q:271-280
  .z.m.reloadcomplete:0b;
  .z.m.reloadsummary:0#.z.m.reloadsummary;
  informgateway (`reloadstart;`);
  live:@[{[] :exec distinct proctype from servers.getservers[`]};::;
         {[e] .z.m.logwarn[`doreload;"could not read the server list: ",e];:`$()}];
  types:.z.m.reloadorder inter live;
  / NB distinct, not a bare count raze: reloadsummary is keyed by handle, so a handle that di.servers
  / registers under more than one proctype - or a reloadorder with a duplicate entry - would still only
  / ever accumulate ONE row per reply. counting the raw (possibly duplicated) handle list here would
  / then make countreload=count reloadsummary unsatisfiable even once every process has replied,
  / silently downgrading the fast release path into always waiting the full eodwaittime
  .z.m.countreload:count distinct raze @[{[ts] :{[t] exec w from servers.getservers[t]} each ts};types;{[e] :()}];
  getprocs[;pt] each types;
  $[.z.m.eodwaittime>0;scheduleflushend[];flushend[]];
  };

/ ============================================================
/ remaining api
/ ============================================================

status:{[]
  / a snapshot of how this wdb is wired and what it currently holds.
  / the readiness check legacy spells .wdb.notpconnected[] (wdb.q:616-617) is the `subscribed key,
  / answered by di.subscriptions rather than by reading its registry from outside. legacy's own
  / predicate has no caller anywhere in TorQ, so it is generalised here rather than ported verbatim
  requireinit[`status];
  / NB the key vector is PARENTHESISED. ! binds tighter than , so an unbracketed continuation would
  / parse as syms,(syms!values) and throw 'length
  :(`started`subscribed`mode`writedownmode`savedir`hdbdir`partition`subtables`tabsizes,
    `permitreload`gc`ignorelist)!
   (.z.m.started;
    $[.z.m.started;@[subscriptions.subscribed;::;{[e] :0b}];0b];
    .z.m.mode;
    .z.m.writedownmode;
    .z.m.savedir;
    .z.m.hdbdir;
    getpartition[];
    .z.m.subtables;
    .z.m.tabsizes;
    .z.m.permitreload;
    .z.m.gc;
    .z.m.ignorelist);
  };

getapimeta:{[]
  / one row per CALLABLE export, for di.torq to register with di.api. init and getapimeta are omitted
  / as framework plumbing. names are bare; di.torq applies the process-wide qualification
  :flip `name`public`descrip`params`return!flip(
    (`version;     1b; "module version string";
       "[]";                                                     "string: version");
    (`start;       1b; "connect to the tickerplant, subscribe, replay the day's log and start the write-down timer";
       "[]";                                                     "null");
    (`teardown;    1b; "remove the root entry points and timer jobs installed by init and start";
       "[]";                                                     "null");
    (`endofday;    1b; "end of day roll - flush every table to disk, sort it, move it to the hdb and trigger reloads";
       "[date: partition being rolled]";                         "null");
    (`endofperiod; 1b; "intraday period roll notification from the tickerplant - logged only";
       "[timestamp: current period; timestamp: next period; dict: process data]"; "null");
    (`status;      1b; "how this wdb is wired and what it currently holds";
       "[]";                                    "dict: started, subscribed, mode, directories, partition and the write-down policy"));
  };
