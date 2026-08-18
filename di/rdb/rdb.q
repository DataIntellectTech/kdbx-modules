/ the real-time database: subscribe to a tickerplant, replay the day's tickerplant log to recover
/ intraday state, accumulate live updates in memory, and at end of day write each table down to the
/ hdb, clear it and tell the hdb(s) to reload.
/ ported from TorQ's code/processes/rdb.q plus code/rdb/rdbstandard.q and code/rdb/endofperiod.q,
/ with defaults from config/settings/rdb.q. see rdb.md for scope, divergences and design rationale.
/ the version lives in the VERSION file and is read by init.q
/ ROOT-NAMESPACE RULES (the same ones that bit every process-tier module so far). a source-level bare
/ identifier in module code is rewritten at load to this module's private namespace, so it can never
/ reach root. therefore:
/   - reading a root table is a bare `value t` / `tables[`.]` - those fall through to root
/   - writing, clearing or dropping targets root EXPLICITLY via @[`.;t;...]
/   - the root entry points (upd, endofday, reload, endofperiod, .u.end) are installed with an
/     explicit @[`.;...] or set[`.u.end;...], never a bare assignment
/ a q-sql select/where/by CLAUSE additionally cannot resolve a module-level name at all, so every
/ config value used in one is hoisted into a function-local first

/ ============================================================
/ constants (load-time)
/ ============================================================

/ where the rdb partition value may be sourced from. anything else yields a null date, which
/ setpartition then fills from pardefault - TorQ rdb.q:30-32 documents exactly that fallthrough
validparvaluesrc:`log`tab;

/ the columns loadsubfilters expects in the subscription-filter csv, keyed on tabname.
/ TorQ rdb.q:189 reads it as 1!("S**";enlist",") - a table name plus two free-text clause columns
subfiltercols:`tabname`filters`columns;

/ the tickerplant-side selection algorithm handed to di.servers.gethandlebytype when config names none
defaultselection:`any;

/ ============================================================
/ internal helpers - config coercion
/ ============================================================

assym:{[x]
  / config values arrive as symbols from a .q settings file or as strings from a .toml one; a sym
  / filter arrives as a DICT (TorQ rdb.q:191 passes .sub.filterparams straight through as the
  / instruments argument) and must pass through untouched. `$ throws 'type on a symbol, so it is
  / NOT idempotent - hence the type checks rather than a blanket cast
  :$[99h=type x;x;11h=abs type x;x;`$x];
  };

aslist:{[x]
  / normalise an atom to a one-element list. deliberately NOT applied to subscribeto/subscribesyms:
  / ` there is the all-tables/all-syms SENTINEL, and di.subscriptions tests it with x~` (an atom
  / match), so enlisting it would turn "everything" into "the table literally named `"
  :$[0>type x;enlist x;x];
  };

ashsym:{[x]
  / normalise a directory setting to an hsym, accepting `:hdb, `hdb, ":hdb" or "hdb"
  s:$[10h=abs type x;(),x;string x];
  :hsym `$$[(0<count s) and ":"=first s;1_s;s];
  };

cfg:{[deps;dflts;k]
  / internal - resolve ONE config key off the single deps dict, falling back to its default. every
  / write in init stays an explicit .z.m.<name>: line so a reviewer can grep which keys reach module
  / state; this only removes the repeated `$[k in key deps;deps k;dflts k]` from each of them
  :$[k in key deps;deps k;dflts k];
  };

configdefaults:{[]
  / every config key init accepts, with its default, taken from TorQ config/settings/rdb.q and the
  / @[value;`var;default] guards at the top of rdb.q. this is the single place the defaults live, and
  / the test suite asserts every key here reached module state - which is what catches a forgotten
  / write in init. a FUNCTION rather than a constant because pardefault is TorQ's .z.D, which must be
  / resolved when init runs, not frozen at module load
  / NB built as ONE key!value pair, not as a chain of joined single-group dicts. joining dicts whose
  / value sides are differently-typed - a symbol vector onto a general list - throws 'type, the same
  / family of trap as joining di.log's logdict to a chain of single-key dicts (measured)
  / NB onlyclearsaved defaults to 1b, where TorQ's default is 0b. this is the ONE default deliberately
  / changed from legacy, and it is a data-safety choice: under 0b a savedown that throws still clears
  / the table, so the day's data is gone and the only trace is one line in the log. 1b keeps the table
  / in memory so the failure is recoverable - the rows are still queryable and can be written by hand.
  / the cost is a table that keeps growing while the save keeps failing, which is loud and bounded by
  / the process, against a silent unrecoverable loss. set it back to 0b for TorQ-identical behaviour.
  / see rdb.md, "design decisions and divergences from TorQ"
  k:`tickerplanttypes`hdbtypes`hdbnames`gatewaytypes`ignorelist,
    `subscribeto`subscribesyms`schema`replaylog`subfiltered`subcsv,
    `hdbdir`sortcsv`savetables`onlyclearsaved`gc,
    `reloadenabled`parvaluesrc`pardefault,
    `upd`savedownmanipulation`postreplay,
    `tpwaittimeout`tppollms`tpselection`resubscribeenabled`resubscribeperiod,
    `suspendtimeoutonroll`timeoutlead`procname`proctype;
  v:(enlist`tickerplant;enlist`hdb;`$();`$();`heartbeat`logmsg;
     `;`;1b;1b;0b;`;
     `:hdb;`;1b;1b;1b;
     0b;`log;.z.D;
     updfn;()!();{[d;p]};
     30000;500;defaultselection;1b;30;
     1b;0D00:01;`;`);
  :k!v;
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
    '"di.rdb: ",string[ctx],": init must be called before any other function"];
  };

requirestart:{[ctx]
  / start[] is what resolves the tickerplant handle and populates subtables. reload and the `tab
  / partition source both read subtables, and would otherwise operate on an empty list and silently
  / do nothing - the failure mode this module is least able to detect after the fact
  requireinit[ctx];
  if[not .z.m.started;
    raiseerror[ctx;"start must be called before this function - no subscription has been established"]];
  };

raiseerror:{[ctx;msg]
  / log an error under ctx then signal it, so a failure is observable in the log and not only as a
  / throw. init's own dependency validation is the one exception - the logger is not wired yet
  .z.m.logerr[ctx;msg];
  '"di.rdb: ",string[ctx],": ",msg;
  };

/ ============================================================
/ root entry points
/ ============================================================

updfn:{[t;x]
  / the default root upd. TorQ's is a bare `insert` (code/rdb/rdbstandard.q, config/settings/rdb.q);
  / this reproduces INSERT semantics (append, not upsert-by-key) but targets root explicitly, and
  / normalises the two payload shapes a subscriber sees: a table, from the live tickerplant feed, and
  / a list of columns, from the -11! log replay.
  / overridable with the `upd config key - a caller that wants upsert, or its own bespoke handler,
  / supplies a root-safe binary function of its own.
  / NB the append MUST go through the four-argument amend @[`.;t;,;data], not through a unary lambda
  / doing tab,data. the lambda form returns a NEW table and silently drops every column attribute -
  / measured: a `g#sym column comes back unattributed after one update, and stays that way for the
  / rest of the day. the amend form modifies in place and maintains the index, which is exactly why
  / TorQ's default upd is the in-place `insert`.
  / the three payload shapes are the ones di.subscriptions' own payloadtable normalises, kept in step
  / with it deliberately: a table, a column DICT, or a plain list of columns. a tickerplant that logs
  / a dict is as valid as one that logs a list, and reaching the list branch with a dict would build
  / (cols)!dict and produce nonsense rather than throwing
  @[`.;t;,;$[98h=type x;x;99h=type x;flip x;flip (cols value t)!x]];
  };

installroot:{[]
  / publish the entry points the rest of the stack calls this process on. all explicit root targets:
  /   upd         - driven by the live feed AND by di.subscriptions' -11! replay, so it must exist
  /                 BEFORE start[] runs (di.subscriptions.requirerootupd refuses to replay without one)
  /   endofday    - the tickerplant's (`endofday;date) broadcast, applied by the default .z.ps
  /   .u.end      - TorQ's alias for the same thing (code/rdb/rdbstandard.q); set[] rather than
  /                 @[`.;...] because a dotted name is not a key of the root namespace dictionary
  /   reload      - the wdb's (`reload;date) call, once it has persisted the prior day
  /   endofperiod - the tickerplant's intraday period roll
  @[`.;`upd;:;.z.m.upd];
  @[`.;`endofday;:;endofday];
  @[`.;`reload;:;reload];
  @[`.;`endofperiod;:;endofperiod];
  set[`.u.end;endofday];
  };

uninstallroot:{[]
  / internal - give back exactly what installroot published. only the names still bound to THIS
  / module's functions are removed: a later module that has taken over one of these root names owns it
  / now, and silently deleting its binding would be a worse outcome than leaving ours behind
  dropifours[`upd;.z.m.upd];
  dropifours[`endofday;endofday];
  dropifours[`reload;reload];
  dropifours[`endofperiod;endofperiod];
  / .u.end is read through a PROTECTED value, not as a bare .u.end. a shutdown path may call teardown
  / twice, and the second call would otherwise die on an unlogged '.u.end reading the name the first
  / call deleted - measured. dropifours already guards the plain root names the same way
  if[endofday~@[value;`.u.end;{[e] :(::)}];![`.u;();0b;enlist`end]];
  };

dropifours:{[nm;f]
  / internal - delete a root name only if it still holds the function we installed there
  if[not nm in key `.;:()];
  if[not f~`. nm;:()];
  ![`.;();0b;enlist nm];
  };

/ ============================================================
/ init and teardown
/ ============================================================

init:{[deps]
  / wire the injected dependencies (log and timer - both REQUIRED, never defaulted) and this module's
  / config, then publish the root entry points. ONE dict carrying dependency and config keys side by
  / side - the call shape di.torq wires every module with.
  / e.g. rdb.init[logging.logdict,`timer`hdbdir`reloadenabled!(timerdep;`:/data/hdb;0b)]
  / NB build deps as ONE multi-key dict. joining di.log's logdict to a chain of single-key dicts -
  / logdict,enlist[`timer]!enlist timerdep - throws 'mismatch, because both value sides are tables.
  / NB init does NO i/o and initialises NO other module. di.servers, di.subscriptions, di.dbwrite and
  / di.eodtime are shared framework state whose lifecycle belongs to the caller (di.torq, or a test
  / harness); this module only USES them, and only from start[] onwards. see rdb.md
  if[99h<>type deps;
    '"di.rdb: deps must be a dict of injectables + config, with `log and `timer keys"];
  if[not all `log`timer in key deps;
    '"di.rdb: log and timer dependencies are required; pass `log (`info`warn`error) and `timer ",
      "(see di.log, di.timer); got: ",(", " sv string key deps)];
  if[99h<>type deps`log;
    '"di.rdb: log value must be a dict; pass `info`warn`error functions - see di.log"];
  if[not all `info`warn`error in key deps`log;
    '"di.rdb: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  if[99h<>type deps`timer;
    '"di.rdb: timer value must be a dict - see di.timer"];
  if[not `addjob in key deps`timer;
    '"di.rdb: timer dict must expose `addjob - see di.timer"];
  if[99h<>type deps[`timer]`addjob;
    '"di.rdb: timer`addjob must be a variant dict - see di.timer addjob.custom/default/simple"];
  if[not `custom in key deps[`timer]`addjob;
    '"di.rdb: timer`addjob must expose the `custom variant [id;func;params;period;mode;opts]"];
  / deletejobs is checked here for the same reason addjob is, and the consequence of NOT checking it
  / is worse than a late error - it is a SILENT one, measured both ways a caller can shape the dep:
  / the timer dep's value side is dict-typed, so a missing key returns a null-shaped DICT
  / ((,`custom)!,::) rather than erroring. teardown's @[.z.m.timer[`deletejobs];ids;handler] then
  / stops being protected-apply at all: @[x;y;z] is "try x[y], catch with z" only when x is a
  / FUNCTION, and here x is a dict, so q reads the whole expression as three-argument AMEND. it
  / upserts the job ids into that throwaway dict using the error handler as the new value, discards
  / the result (nothing in teardown captures it) and carries on. nothing throws, nothing warns, the
  / timer jobs are never deleted, and teardown still logs "timeout job removed" - which is false
  if[not `deletejobs in key deps`timer;
    '"di.rdb: timer dict must expose `deletejobs - teardown needs it, and a timer dep without it ",
      "fails SILENTLY at teardown rather than loudly here; see di.timer"];
  / presence is NOT enough: a non-callable deletejobs reaches teardown's @[...] and lands in the same
  / amend interpretation as a missing key, so it also returns quietly having deleted nothing.
  / 100 112h spans every callable form - lambda, primitive, operator, iterator, projection,
  / composition - so a legitimate projection like deletejobs:somefn[;x] is not rejected
  if[not (type deps[`timer]`deletejobs) within 100 112h;
    '"di.rdb: timer`deletejobs must be a function [ids]; a non-callable value fails silently at ",
      "teardown - see di.timer"];
  / disabletimeout was renamed to suspendtimeoutonroll (same meaning, 1b = suspend around the roll).
  / rejected rather than silently ignored: the only callers who ever set it explicitly are the ones
  / who set it to 0b to turn the suspend OFF, and silently dropping that override would flip them
  / back to suspend-enabled - a behaviour change for exactly the config that was deliberately
  / non-default. a caller who never set it is unaffected either way and never sees this
  if[`disabletimeout in key deps;
    '"di.rdb: disabletimeout has been renamed to suspendtimeoutonroll (same meaning: 1b suspends ",
      "the query timeout around the roll); update your config"];
  / resolve and VALIDATE config before any state is mutated, so a rejected re-init cannot leave the
  / module half-configured with a wired logger and a nonsense partition source
  d:configdefaults[];
  c:cfg[deps;d];
  pvs:assym c`parvaluesrc;
  if[not pvs in validparvaluesrc;
    '"di.rdb: parvaluesrc must be one of ",(", " sv string validparvaluesrc),"; got: ",string pvs];
  / 100 112h, not 100h=type. a bare `100h=type` accepts only a lambda and rejects every other binary
  / function a caller might reasonably pass: TorQ's own default upd is `insert` (102h), rdb.md tells
  / callers to supply `upsert` if they want upsert semantics (104h), and a projection is 104h too.
  / all three are binary and root-safe - insert/upsert take the table by SYMBOL, so they write to root
  / exactly as updfn does - and all three were rejected before this widened
  if[not (type c`upd) within 100 112h;
    '"di.rdb: upd must be a binary function taking (tablename;data)"];
  if[99h<>type c`savedownmanipulation;
    '"di.rdb: savedownmanipulation must be a dict of tablename!function"];
  / a non-positive or uncastable period would schedule the recovery job to run every cycle, or throw
  / from inside di.timer where the message would name the timer rather than the offending config key
  rsp:@[{"j"$x};c`resubscribeperiod;{[e] :0N}];
  if[(null rsp) or 0>=rsp;
    '"di.rdb: resubscribeperiod must be a positive whole number of seconds; got: ",
      .Q.s1 c`resubscribeperiod];
  / is this the FIRST init in this process? read it BEFORE any write, because initialised[] probes
  / hdbdir and this must reflect the state on entry
  fresh:not initialised[];
  .z.m.loginfo:(deps`log)`info;
  .z.m.logwarn:(deps`log)`warn;
  .z.m.logerr:(deps`log)`error;
  .z.m.timer:deps`timer;
  / one explicit write per config key - a dynamic loop over the dict would hide a missing key
  / completely, because a bare read of an unwritten name resolves silently to nothing
  .z.m.tickerplanttypes:aslist assym c`tickerplanttypes;
  .z.m.hdbtypes:aslist assym c`hdbtypes;
  .z.m.hdbnames:aslist assym c`hdbnames;
  .z.m.gatewaytypes:aslist assym c`gatewaytypes;
  .z.m.ignorelist:aslist assym c`ignorelist;
  .z.m.subscribeto:assym c`subscribeto;
  .z.m.subscribesyms:assym c`subscribesyms;
  .z.m.schema:`boolean$c`schema;
  .z.m.replaylog:`boolean$c`replaylog;
  .z.m.subfiltered:`boolean$c`subfiltered;
  .z.m.subcsv:c`subcsv;
  .z.m.sortcsv:c`sortcsv;
  .z.m.savetables:`boolean$c`savetables;
  .z.m.onlyclearsaved:`boolean$c`onlyclearsaved;
  .z.m.gc:`boolean$c`gc;
  .z.m.reloadenabled:`boolean$c`reloadenabled;
  .z.m.parvaluesrc:pvs;
  .z.m.pardefault:c`pardefault;
  .z.m.upd:c`upd;
  .z.m.savedownmanipulation:c`savedownmanipulation;
  .z.m.postreplay:c`postreplay;
  .z.m.tpwaittimeout:"j"$c`tpwaittimeout;
  .z.m.tppollms:"j"$c`tppollms;
  .z.m.tpselection:assym c`tpselection;
  .z.m.resubscribeenabled:`boolean$c`resubscribeenabled;
  .z.m.resubscribeperiod:rsp;
  .z.m.suspendtimeoutonroll:`boolean$c`suspendtimeoutonroll;
  .z.m.timeoutlead:c`timeoutlead;
  .z.m.procname:assym c`procname;
  .z.m.proctype:assym c`proctype;
  / hdbdir is written LAST of the config keys because initialised[] probes it - a re-init that threw
  / part way through must not leave the module reporting itself as ready
  .z.m.hdbdir:ashsym c`hdbdir;
  / RUNTIME state is seeded only on a FRESH init. a re-init - di.torq re-applying config, a config
  / reload, a second wiring - must not wipe a live rdb's subscription, partition list or eod snapshot.
  / measured: wiping eodtabcount between the roll and the wdb's reload[date] leaves the prior day in
  / memory permanently, because reload then has nothing to drop (and requirestart throws first, since
  / started was reset too) - silently doubling what the rdb holds, which is the exact failure this
  / module exists to prevent. di.subscriptions sets the same precedent, seeding its registry only when
  / fresh; the dependency and config writes above are refreshed unconditionally, as di.servers does.
  / eodtabcount is a TYPED empty dict: an untyped ()!() makes `0^eodtabcount t` return a general empty
  / list rather than the zeros reload needs, and the drop then throws (measured)
  if[fresh;
    .z.m.rdbpartition:0#0Nd;
    .z.m.subtables:`$();
    .z.m.tplogdate:0Nd;
    .z.m.eodtabcount:(`$())!`long$();
    .z.m.filterparams:()!();
    .z.m.timeout:0i;
    / timeoutsuspended tracks whether THIS module is the one currently holding the query timeout at
    / zero. without it both halves of the suspension are unconditional and clobber an operator's \T -
    / see timeoutreset/restoretimeout
    .z.m.timeoutsuspended:0b;
    .z.m.started:0b];
  installroot[];
  .z.m.loginfo[`init;"di.rdb initialised - hdbdir ",(string .z.m.hdbdir),", reloadenabled ",
    (string .z.m.reloadenabled),", parvaluesrc ",string .z.m.parvaluesrc];
  };

teardown:{[]
  / release everything init and start installed process-wide: the root entry points and the pre-roll
  / timeout job. paired with init's side effects, the way di.subscriptions.teardown is paired with its
  / .z.pc registration. module state is deliberately LEFT INTACT so a shutdown path can still inspect
  / the partition list and the eod snapshot; only the process-global bindings are withdrawn
  requireinit[`teardown];
  uninstallroot[];
  / deleting a job that was never scheduled is a no-op in di.timer (it is a delete-where over the jobs
  / table), so neither id has to exist; both go in ONE call for that reason.
  / NB this @[...] is protected-apply ONLY because init guarantees `deletejobs is present and is a
  / function. @[x;y;z] is "try x[y], catch with z" solely when x is a function - if the key were
  / missing, x would be the null-shaped DICT a dict-valued dep returns for an absent key, and q would
  / read this as three-argument AMEND instead: it would upsert the ids into that throwaway dict using
  / the handler as the value, discard the result, and carry on having deleted nothing and logged
  / nothing (measured). the init check is what keeps this line honest - do not drop it
  @[.z.m.timer[`deletejobs];`rdbtimeoutreset`rdbresubscribe;
    {[e] .z.m.logwarn[`teardown;"could not delete the rdb timer jobs: ",e]}];
  .z.m.started:0b;
  .z.m.loginfo[`teardown;"di.rdb root entry points and timeout job removed"];
  };

/ ============================================================
/ query-timeout suspension around the roll
/ ============================================================

timeoutreset:{[]
  / suspend the query timeout ahead of the eod writedown, remembering what it was. TorQ rdb.q:206 -
  / a \T that expires mid-writedown aborts the roll, so it is disabled BEFORE the roll rather than at
  / the top of endofday, where changing it mid-execution would be racing the very timer it sets.
  / GUARDED against a second suspend while already suspended. legacy recaptures unconditionally, so a
  / day whose restore never ran (a wdb that missed its reload[date]) captures the ZERO this function
  / itself set, and every later restore then puts back 0 - the query timeout is disabled for the life
  / of the process. measured on the unguarded form: suspend, suspend, restore -> \T 0, not the
  / original 30. recapturing is never useful anyway, since the only value it could find is our own 0
  if[.z.m.timeoutsuspended;
    .z.m.logwarn[`timeoutreset;"query timeout is already suspended (",(string .z.m.timeout),
      "s held) - not recapturing, the previous roll never restored it"];
    :()];
  .z.m.timeout:system"T";
  .z.m.timeoutsuspended:1b;
  system"T 0";
  .z.m.loginfo[`timeoutreset;"query timeout suspended for the eod writedown (was ",
    (string .z.m.timeout),"s)"];
  };

restoretimeout:{[]
  / put the timeout back once the writedown is done - TorQ rdb.q:207.
  / a NO-OP unless this module actually suspended it. legacy restores unconditionally, which writes
  / the seeded 0 over whatever the operator had set whenever a roll happens without a preceding
  / suspend - and that is not an edge case: savecycle calls this on EVERY standalone roll, so with
  / suspendtimeoutonroll 0b (no suspension job scheduled at all) the very first end of day silently does
  / `system"T 0"` and disables the query timeout permanently. measured: \T 30, one endofday, \T 0
  if[not .z.m.timeoutsuspended;
    :()];
  system"T ",string .z.m.timeout;
  .z.m.timeoutsuspended:0b;
  .z.m.loginfo[`restoretimeout;"query timeout restored to ",(string .z.m.timeout),"s"];
  };

requirenextroll:{[ctx]
  / internal - di.eodtime must have been initialised by the caller before a roll time can be read off
  / it. 0Wp is its pre-init value; scheduling against that would book the job for the end of time and
  / nothing would ever fire - a silent no-op that only surfaces as an aborted roll months later.
  / start[] calls this EARLY, before the tickerplant round trip, because subscribing registers this
  / handle for live delivery and nothing can undo that - di.subscriptions orders its own guards the
  / same way and for the same reason
  if[0Wp=eodtime.getnextroll[];
    raiseerror[ctx;"di.eodtime reports no next roll (0Wp) - call di.eodtime.init before ",
      "di.rdb.start, or set suspendtimeoutonroll to 0b"]];
  };

scheduletimeoutreset:{[]
  / schedule timeoutreset shortly before the next eod roll, repeating daily. this is TorQ rdb.q:238
  / ported to the injected timer, and it is the ONE thing that makes di.eodtime a real dependency of
  / this module rather than a declared one - .eodtime.nextroll is the only .eodtime reference in the
  / whole of TorQ's rdb.q.
  / TorQ additionally subtracts a 15-minute-rounded (.proc.cp[]-.z.p) term. that difference is zero
  / outside backtesting, where .proc.cp[] is overridden to simulate a clock, so it is dropped rather
  / than ported without the simulated-clock machinery that gives it meaning
  if[not .z.m.suspendtimeoutonroll;
    .z.m.loginfo[`scheduletimeoutreset;"suspendtimeoutonroll is off - the query timeout will not ",
      "be suspended for the writedown"];
    :()];
  requirenextroll[`scheduletimeoutreset];
  startp:eodtime.getnextroll[]-.z.m.timeoutlead;
  / mode 1h schedules `period` SECONDS after the previously scheduled start, so 86400 is TorQ's 1D
  / repeat. maxruns 0Wi keeps it running for the life of the process
  @[{.z.m.timer[`addjob][`custom][`rdbtimeoutreset;timeoutreset;();86400;1;
      `startattime`maxruns!(x;0Wi)]};
    startp;
    {[e] .z.m.logwarn[`scheduletimeoutreset;"could not schedule the timeout job: ",e]}];
  .z.m.loginfo[`scheduletimeoutreset;"timeout suspension scheduled for ",string startp];
  };

/ ============================================================
/ partition tracking (the gateway's view of what this rdb holds)
/ ============================================================

logpartition:{[]
  / internal - TorQ logs the partition list under its own `rdbpartition context on every change
  / (rdb.q:88,151), so an operator can grep one context for the whole history of what the rdb held
  .z.m.loginfo[`rdbpartition;"rdbpartition contains - ","," sv string .z.m.rdbpartition];
  };

partfromlog:{[]
  / the tickerplant log file's date, as di.subscriptions reports it from the log file NAME - TorQ
  / rdb.q:179-180 reads the same thing off .rdb.tplogdate
  .z.m.loginfo[`setpartition;"setting rdbpartition from date in tickerplant log file name : ",
    string .z.m.tplogdate];
  :.z.m.tplogdate;
  };

partfromtab:{[]
  / the date of the first time value in the largest subscribed table - TorQ rdb.q:181-183. the time
  / column must be a timestamp or datetime for the cast to yield a real date; anything else falls
  / through to pardefault, exactly as legacy does
  st:.z.m.subtables;
  if[0=count st;
    .z.m.logwarn[`setpartition;"parvaluesrc is `tab but no table is subscribed - falling back to pardefault"];
    :0Nd];
  largest:first st idesc count each value each st;
  .z.m.loginfo[`setpartition;"setting rdbpartition from largest table (",(string largest),")"];
  :.[$;(`date;first (value largest)`time);0Nd];
  };

setpartition:{[]
  / establish the partition value this rdb holds, for a gateway to route on. TorQ rdb.q:178-186.
  / NB written as a dispatch rather than legacy's $[cond;[stmt;stmt];...]: a bare bracket sequence at
  / expression level parses as INDEXING in kdb-x, not as a statement block, so legacy's shape would
  / silently evaluate as partfromlog[tplogdate] instead of running both statements
  requireinit[`setpartition];
  pv:$[`log=.z.m.parvaluesrc;partfromlog[];`tab=.z.m.parvaluesrc;partfromtab[];0Nd];
  .z.m.rdbpartition:enlist .z.m.pardefault^pv;
  logpartition[];
  };

rmdtfromgetpar:{[date]
  / drop a date from the partition list once it has been written down or handed to the wdb -
  / TorQ rdb.q:149-152
  .z.m.rdbpartition:.z.m.rdbpartition except date;
  logpartition[];
  };

getpartition:{[]
  / the partitions this rdb currently holds. TorQ's rdb.q:199 api function, read by the gateway and
  / by the data-access layer (code/dataaccess/getdata.q:31-33) to decide whether a query's date range
  / reaches into the rdb at all
  requireinit[`getpartition];
  :.z.m.rdbpartition;
  };

getattributes:{[]
  / the process attributes a gateway caches for this rdb - code/rdb/rdbstandard.q's
  / .proc.getattributes. tables[] is the ROOT table list, which is what a gateway needs to know
  :`partition`tables!((),.z.m.rdbpartition;tables[`.]);
  };

/ ============================================================
/ connection helpers
/ ============================================================

handlesbytypeandname:{[types;names]
  / internal - every live handle whose proctype is in types OR whose procname is in names, unioned.
  / TorQ rdb.q:120 runs the two lookups separately and razes them, so a process named in hdbnames is
  / notified even when its proctype is not in hdbtypes - an intersection would silently drop it.
  / types and names are hoisted into LOCALS: a module-level name cannot be resolved inside a q-sql
  / where clause at all, only function-locals and column names can
  tt:types;
  nn:names;
  srvs:servers.getservers[`];
  bytype:$[0=count tt;0#srvs;select from srvs where proctype in tt];
  byname:$[0=count nn;0#srvs;select from srvs where procname in nn];
  :distinct exec w from bytype,byname;
  };

hdbhandles:{[] :handlesbytypeandname[.z.m.hdbtypes;.z.m.hdbnames]};

gatewayhandles:{[] :handlesbytypeandname[.z.m.gatewaytypes;`$()]};

/ ============================================================
/ start - the i/o phase
/ ============================================================

connecttp:{[]
  / internal - open the configured connections, block until a tickerplant is up, and hand back a
  / handle to it. the port of TorQ rdb.q:225-229: .servers.startupdepcycles becomes
  / di.servers.waitfortype, so tpconnsleepintv/tpcheckcycles collapse into tppollms/tpwaittimeout.
  / NB di.servers.startup[] takes no argument - it opens whatever the CALLER configured di.servers
  / with. supplying a connections list covering the tickerplant and hdb proctypes is therefore part
  / of wiring di.servers, not something this module can do for it. see rdb.md
  servers.startup[];
  tpt:first .z.m.tickerplanttypes;
  if[not servers.waitfortype[tpt;.z.m.tpwaittimeout;.z.m.tppollms];
    raiseerror[`start;"no ",(string tpt)," connection within ",(string .z.m.tpwaittimeout),
      "ms - cannot start the rdb"]];
  tph:servers.gethandlebytype[tpt;.z.m.tpselection];
  if[null tph;
    raiseerror[`start;"di.servers reported a ",(string tpt)," connection but returned no handle"]];
  :tph;
  };

start:{[]
  / connect to the tickerplant, subscribe, and replay the day's log. split out of init deliberately:
  / init is pure configuration and can be unit-tested with no sockets and no other module initialised,
  / whereas everything here needs di.servers, di.subscriptions, di.dbwrite and di.eodtime already
  / wired by the caller. TorQ makes the same split - .rdb.subscribe[] is its own function, called at
  / the end of rdb.q rather than inline with the config
  requireinit[`start];
  / everything that can be checked WITHOUT talking to the tickerplant is checked first. subscribing
  / registers this handle for live delivery and there is no way to undo it, so a missing di.eodtime
  / must fail before that, not after - otherwise start[] throws with a live subscription behind it
  if[.z.m.suspendtimeoutonroll;requirenextroll[`start]];
  / RESUME PATH. everything after the subscribe can throw, and a subscription cannot be undone, so a
  / start[] that failed part way used to be unrecoverable: the subscription was live, started was 0b,
  / and re-running start[] hit di.subscriptions' rejection of a duplicate subscribe on a handle it
  / already holds. skipping the connect-and-subscribe when one is already live makes the retry work.
  / this is viable because init seeds RUNTIME state (subtables, tplogdate) only on the first call, so
  / what the failed attempt learned from the tickerplant is still in module state to resume from.
  / subscribed[] is read through the same guard resubscribecheck and status use - a throw is read as
  / "not subscribed", which retries the subscribe rather than skipping it, the safe way to be wrong
  / an ALREADY-COMPLETED start is a no-op, not a resume. without this the resume path below turns a
  / second start[] on a healthy rdb into a silent re-run: setpartition is idempotent, but the two
  / addjob calls are not, so it booked a SECOND rdbtimeoutreset and rdbresubscribe against the same
  / ids (measured: 2 jobs became 4). before the resume path existed this case threw, because the
  / subscribe was reached and di.subscriptions rejected the duplicate - the guard restores that
  / protection without giving up the resume. teardown sets started 0b, so start[] after a teardown
  / still works. idempotent like teardown, which rdb.md already documents as safe to call twice
  if[.z.m.started;
    .z.m.loginfo[`start;"start has already completed - nothing to do"];
    :()];
  / read this BEFORE subscribing - after the subscribe it is true on every path, resume or not.
  / two if[]s rather than $[resuming;…;[…]]: a bracket statement block is the shape setpartition
  / deliberately avoids, and this module keeps one convention for it
  resuming:@[subscriptions.subscribed;::;{[e] :0b}];
  if[resuming;
    .z.m.loginfo[`start;"a subscription is already live - resuming start without re-subscribing"]];
  if[not resuming;
    tph:connecttp[];
    if[.z.m.subfiltered;loadsubfilters[]];
    .z.m.loginfo[`start;"found available tickerplant, attempting to subscribe"];
    r:subscriptions.subscribe[tph;.z.m.subscribeto;.z.m.subscribesyms;.z.m.schema;.z.m.replaylog];
    .z.m.subtables:(),r`subtables;
    .z.m.tplogdate:r`tplogdate;
    .z.m.loginfo[`start;"subscribed to ",(", " sv string .z.m.subtables),"; tickerplant log date ",
      string .z.m.tplogdate]];
  / the replay drove the ROOT upd, which is unfiltered - so a filtered subscription has to narrow what
  / the replay put in the tables afterwards. TorQ rdb.q:175-176 does exactly this, and only when both
  / flags are set
  if[.z.m.subfiltered and .z.m.replaylog;applyfilters each .z.m.subtables];
  / the sort/attribute config di.dbwrite applies on savedown - TorQ rdb.q:220 loads the same csv
  if[not .z.m.sortcsv~`;dbwrite.readcsv .z.m.sortcsv];
  setpartition[];
  scheduletimeoutreset[];
  scheduleresubscribe[];
  / started is set LAST, not straight after subscribe. everything between the subscribe and here can
  / throw - an unparseable subscription filter, an unreadable sortcsv, a di.eodtime that reports no
  / roll - and setting it early meant such a failure left the module claiming started 1b with an empty
  / partition list and no timeout or resubscribe job: a half-started rdb that status[] reported as
  / healthy. started now means "start[] completed", which is what every requirestart caller assumes.
  / a partial start leaves a LIVE subscription behind and started 0b, which status[] reports honestly
  / - and start[] is now re-runnable from there via the resume path above, so recovery no longer
  / needs a process restart. NB a fault that is itself persistent (an unparseable subscription filter,
  / an unreadable sortcsv) will throw again on the retry: that is correct, not a loop - the operator
  / fixes the file and calls start[] once more. see rdb.md
  .z.m.started:1b;
  };

/ ============================================================
/ resubscribe - recovering a dropped tickerplant subscription
/ ============================================================

resubscribecheck:{[]
  / internal - the body of the scheduled `rdbresubscribe job.
  / when the tickerplant bounces, di.servers reopens the socket on its own retry cycle, but the
  / reopened handle is a NEW one and the tickerplant holds no subscription against it. without this
  / the rdb sits connected and silently receives nothing for the rest of the day. nothing else in the
  / process notices: the socket is up, so di.servers is satisfied, and no error is ever raised. this
  / job is the only thing that closes that window - recovery is not something an operator can be
  / expected to spot and trigger by hand, because there is no symptom to spot until data is missing.
  / di.subscriptions deliberately keeps the knowledge of WHAT was subscribed and leaves WHEN to
  / re-establish it to this module (see the comment on its resubscribe) - this is that decision.
  / NEVER THROWS. di.timer defaults disableonfail to 1b, so one escaping error would disable the job
  / for the life of the process and take the whole recovery path down with it - which is the exact
  / silent failure this job exists to prevent. scheduleresubscribe ALSO registers it with
  / disableonfail 0b; the two are deliberate belt and braces, not a redundancy to tidy up
  if[not .z.m.started;:()];
  / a subscribed[] that throws is read as "not subscribed": a resubscribe attempt is protected and
  / costs one round trip, whereas skipping one leaves the feed dead until someone notices
  if[@[subscriptions.subscribed;::;{[e] :0b}];:()];
  tpt:first .z.m.tickerplanttypes;
  tph:@[{[t;s] :servers.gethandlebytype[t;s]}[tpt];.z.m.tpselection;
        {[t;e] .z.m.logwarn[`resubscribe;"could not resolve a ",(string t)," handle: ",e];:0N}[tpt]];
  if[null tph;
    .z.m.logwarn[`resubscribe;"subscription is down and no ",(string tpt)," handle is available ",
      "yet - waiting for di.servers to reconnect"];
    :()];
  .z.m.loginfo[`resubscribe;"subscription is down - re-establishing on handle ",.Q.s1 tph];
  / NB neither the log replay nor the subscription filters are re-applied. di.subscriptions.resubscribe
  / passes replay 0b, so nothing is re-read from the tickerplant log and the tables are not double-fed;
  / live data arrives already filtered by the tickerplant, which is why applyfilters is start-only
  done:@[subscriptions.resubscribe;tph;
         {[e] .z.m.logerr[`resubscribe;"resubscribe failed: ",e];:`$()}];
  if[0=count done;
    .z.m.logwarn[`resubscribe;"resubscribe re-established nothing - retrying on the next cycle"];
    :()];
  / subtables is deliberately NOT rewritten from the result. it records what start[] established, and
  / reload walks it to decide what the wdb has persisted; narrowing it here because a tickerplant came
  / back publishing less would silently shrink what the next reload cleans up
  .z.m.loginfo[`resubscribe;"re-established ",", " sv string done];
  };

scheduleresubscribe:{[]
  / schedule resubscribecheck to run every resubscribeperiod seconds for the life of the process.
  / mode 3 - period measured from the previous END, not the previous scheduled start - because the
  / check makes an ipc round trip through di.subscriptions.resubscribe; under mode 1 a run that is
  / slower than the period would have its successor already due the moment it finished.
  / disableonfail 0b: a recovery job that switches itself off on its first bad cycle is worse than no
  / recovery job at all, since it fails exactly when the tickerplant is already misbehaving
  if[not .z.m.resubscribeenabled;
    .z.m.logwarn[`scheduleresubscribe;"resubscribeenabled is off - a dropped tickerplant ",
      "subscription will NOT be re-established automatically"];
    :()];
  @[{.z.m.timer[`addjob][`custom][`rdbresubscribe;resubscribecheck;();x;3;
      `maxruns`disableonfail!(0Wi;0b)]};
    .z.m.resubscribeperiod;
    {[e] .z.m.logwarn[`scheduleresubscribe;"could not schedule the resubscribe job: ",e]}];
  .z.m.loginfo[`scheduleresubscribe;"resubscribe check scheduled every ",
    (string .z.m.resubscribeperiod),"s"];
  };

/ ============================================================
/ subscription filters
/ ============================================================

loadsubfilters:{[]
  / read the subscription-filter csv and rewrite the subscription request from it - TorQ rdb.q:188-191.
  / the csv is keyed on tabname, so its key gives the tables to subscribe to and the whole dict becomes
  / the sym selector. di.subscriptions accepts a 99h dict there (requiresymspec) and forwards it to the
  / tickerplant as a filter, which is legacy's own contract
  if[.z.m.subcsv~`;
    raiseerror[`loadsubfilters;"subfiltered is set but no subcsv was configured"]];
  / hsym is applied once and is idempotent on a path that already carries the leading colon, so there
  / is no second normalisation step here
  f:hsym `$$[10h=abs type .z.m.subcsv;(),.z.m.subcsv;string .z.m.subcsv];
  p:@[{1!("S**";enlist",") 0: x};f;
      {[f;e] raiseerror[`loadsubfilters;"failed to load subcsv ",(string f),": ",e]}[f]];
  if[not all subfiltercols in cols[p],keys p;
    raiseerror[`loadsubfilters;"subcsv must have columns ",", " sv string subfiltercols]];
  .z.m.filterparams:p;
  .z.m.subscribeto:(),raze value flip key p;
  .z.m.subscribesyms:p;
  .z.m.loginfo[`loadsubfilters;"loaded subscription filters for ",", " sv string .z.m.subscribeto];
  };

applyfilters:{[t]
  / re-apply this table's configured filter to what the log replay left in it - TorQ rdb.q:193-196.
  / live data is already filtered by the tickerplant; only the replay needs this.
  / ONE deliberate difference from legacy: it builds the select against the table NAME (eval(?;t;..)),
  / which from module code would resolve the symbol somewhere other than root, so the table VALUE is
  / passed instead and the narrowed result written back with an explicit root target.
  / the eval STAYS. it is not decoration around an applied functional select - applying the same
  / arguments directly, ?[value t;filters;0b;columns], throws 'type, with and without an extra enlist
  / on the constraint (measured on both forms). qlint flags eval as a debug function; this is one of
  / the cases where it is the operation, not a debugging leftover
  f:.z.m.filterparams;
  if[not t in key f;:()];
  filters:$[all null w:f[t;`filters];();@[parse;"select from t where ",w;
    {[t;e] raiseerror[`applyfilters;"unparseable filter for ",(string t),": ",e]}[t]] 2];
  columns:last $[all null c:f[t;`columns];();@[parse;"select ",c," from t";
    {[t;e] raiseerror[`applyfilters;"unparseable column list for ",(string t),": ",e]}[t]]];
  @[`.;t;:;eval(?;value t;filters;0b;columns)];
  .z.m.loginfo[`applyfilters;"applied subscription filter to replayed ",string t];
  };

/ ============================================================
/ column attributes - captured before a wipe, reapplied after
/ ============================================================

grabattrs:{[t]
  / the column!attribute dict for one root table. both a 0# clear and an n _ drop discard attributes,
  / so they are captured before and put back after - TorQ rdb.q:104 and rdb.q:132
  :exec c!a from (0!meta value t) where not null a;
  };

reapplyattrs:{[t;atts]
  / put captured attributes back on a root table. legacy applies a functional update to the table NAME
  / (![`trade;();0b;..]); this operates on the VALUE and writes the result back with an explicit root
  / target, because a name-based amend from module code does not reliably reach root.
  / the update dict maps each column to the parse tree ((#);enlist att;col), i.e. `att#col - the
  / enlist is what makes the attribute a literal rather than a column reference
  if[0=count atts;:()];
  u:(key atts)!{[c;at] :((#);enlist at;c)}'[key atts;value atts];
  .[{@[`.;x;:;![value x;();0b;y]]};(t;u);
    {[t;e] .z.m.logerr[`reapplyattrs;"failed to reapply attributes to ",(string t),": ",e]}[t]];
  };

/ ============================================================
/ end-of-day writedown
/ ============================================================

cleartable:{[t]
  / TorQ rdb.q:47 - explicit root target
  .z.m.loginfo[`writedown;"clearing table ",string t];
  @[`.;t;0#];
  };

manipulate:{[t;x]
  / apply the configured save-down manipulation for this table, falling back to the unmodified data on
  / failure - the port of TorQ's .save.manipulate (code/common/dbwriteutils.q:75). a manipulation that
  / throws must not lose the day's data, so the error is logged and the original table saved
  if[not t in key .z.m.savedownmanipulation;:x];
  :@[.z.m.savedownmanipulation t;x;
     {[t;x;e] .z.m.logerr[`manipulate;"save down manipulation failed for ",(string t),": ",e];:x}[t;x]];
  };

savetable:{[dir;pv;t]
  / save one root table to its hdb partition and then clear it - TorQ rdb.q:49-67.
  / ok starts TRUE so that savetables 0b still counts as "saved" for the clear decision below, which
  / is legacy's own reason for initialising the flag before the guard rather than inside it.
  / NB nothing here pre-sorts. legacy calls .sort.sorttab on the in-memory table and then writes it;
  / di.dbwrite.savedown writes and then sorts and attributes the partition on disk from the same
  / sort config. same end state, one pass instead of two - sorting first would just be thrown away
  ok:1b;
  if[.z.m.savetables;
    .z.m.loginfo[`savetable;"attempting to save ",(string count value t)," rows of table ",
      (string t)," to ",string dir];
    r:.[{[dir;pv;t] dbwrite.savedown[dir;pv;t;manipulate[t;value t]];:(1b;`)};(dir;pv;t);
         {[e] :(0b;e)}];
    ok:first r;
    $[ok;
      .z.m.loginfo[`savetable;"successfully saved table ",string t];
      .z.m.logerr[`savetable;"failed to save table ",(string t),", error was: ",last r]]];
  / clear per the configured policy: onlyclearsaved keeps a table whose save failed, so the day's data
  / is still in memory to be recovered rather than dropped on the floor
  $[.z.m.onlyclearsaved;
    $[ok;
      cleartable t;
      .z.m.logwarn[`savetable;"table ",(string t)," was not saved correctly and will not be wiped"]];
    cleartable t];
  };

writedown:{[dir;pv]
  / save every non-ignored root table, smallest first - TorQ rdb.q:70-74. the ordering is legacy's:
  / the small tables land on disk quickly, so a failure part way through has already persisted most of
  / the tables rather than none of them
  t:tables[`.] except .z.m.ignorelist;
  t:t iasc count each value each t;
  savetable[dir;pv] each t;
  };

runpostreplay:{[date]
  / the user-defined post-writedown hook - TorQ's .save.postreplay (dbwriteutils.q:82), invoked after
  / every table has been written down (rdb.q:118). protected: a broken hook must not abort the roll
  / after the data is already safely on disk
  .[.z.m.postreplay;(.z.m.hdbdir;date);
    {[e] .z.m.logerr[`postreplay;"post replay function failed: ",e]}];
  };

hdbmessage:{[date]
  / the message an hdb is sent to make it pick up the partition just written - TorQ rdb.q:77, kept as
  / its own function for the same reason legacy did: it is the extension point for an hdb that names
  / its reload entry point differently
  :(`reload;date);
  };

notifyhdbs:{[date]
  / tell every connected hdb to reload - TorQ rdb.q:80-83,120.
  / legacy sends a separate SYNC message per handle, so the roll waits for every hdb in turn.
  / di.asyncutil.postback broadcasts through -25!, so the message is serialised ONCE for all of them
  / and each handle's send is error-trapped into a success vector rather than throwing. it is genuinely
  / fire-and-forget: postback flushes the outgoing queue and returns without waiting for any reply, so
  / a slow or hung hdb cannot stall the roll. the success vector means "on the wire", not "reloaded"
  / NB postback requires POSITIVE handles. legacy's .async.send negates (neg abs handles); di.asyncutil
  / does not, and a negative handle there returns a caught "-4 is not an ipc handle" failure rather
  / than throwing - a silent no-notify if it were passed through unchecked (measured)
  h:hdbhandles[];
  if[0=count h;
    .z.m.logwarn[`notifyhdb;"no hdb connected to notify for reload"];
    :()];
  .z.m.loginfo[`notifyhdb;"sending reload for ",(string date)," to ",(string count h)," hdb handle(s)"];
  sent:@[asyncutil.postback[abs h;hdbmessage date;];reloadreply;
    {[e] .z.m.logerr[`notifyhdb;"failed to send reload message to the hdbs: ",e];:enlist 0b}];
  / postback returns TWO different shapes: a plain boolean vector when the broadcast went out, and
  / (booleanvector;errorstring) when it did not. so the flags are the whole result in one case and its
  / first element in the other - dispatch on type rather than letting `first` happen to suit both,
  / which it only does because the success vector is uniform
  ok:$[1h=type sent;sent;(),first sent];
  if[not all ok;
    .z.m.logerr[`notifyhdb;"reload message was not accepted by every hdb handle"]];
  };

reloadreply:{[r]
  / the postback di.asyncutil installs on the hdb's reply. legacy discards the sync result; keeping it
  / means a reload that fails ON THE HDB is visible here rather than only in the hdb's own log
  .z.m.loginfo[`notifyhdb;"hdb reload replied: ",.Q.s1 r];
  };

pushattributes:{[]
  / tell the gateways what this rdb now holds, so they stop routing the rolled day here - TorQ
  / rdb.q:99-100. a no-op unless gatewaytypes is configured, which it is not by default: a plain rdb
  / with no gateway in the stack should not be looking for one
  if[0=count .z.m.gatewaytypes;:()];
  h:gatewayhandles[];
  if[0=count h;
    .z.m.logwarn[`endofday;"no gateway connected to send eod attributes to"];
    :()];
  msg:(`setattributes;.z.m.procname;.z.m.proctype;getattributes[]);
  @[asyncutil.postback[abs h;msg;];{[r] :(::)};
    {[e] .z.m.logerr[`endofday;"failed to push eod attributes to the gateways: ",e]}];
  .z.m.loginfo[`endofday;"pushed eod attributes to ",(string count h)," gateway handle(s)"];
  };

deferwritedown:{[]
  / wdb-fronted mode. a wdb owns the on-disk writedown, so this rdb saves and clears NOTHING: it only
  / snapshots how many rows each table held at the roll, so the wdb's later reload[date] call can drop
  / exactly the prior day and keep the new day's ticks. the data stays live and queryable until then.
  / TorQ rdb.q:95-101.
  / NB the snapshot covers EVERY root table, not tables-except-ignorelist. that asymmetry with the
  / standalone path is legacy's and is deliberate: reload drops from the subscribed tables, and a
  / count that was never taken would drop nothing rather than fail
  / the `long$ cast keeps the dict typed when there are no root tables at all: an untyped empty dict
  / makes reload's `0^eodtabcount t` yield a general empty list rather than zeros (measured)
  t:tables[`.];
  .z.m.eodtabcount:t!`long$count each value each t;
  .z.m.loginfo[`endofday;"reload is enabled - storing counts of tables at EOD : ",
    .Q.s1 .z.m.eodtabcount];
  pushattributes[];
  .z.m.loginfo[`endofday;"escaping end of day function"];
  };

savecycle:{[date]
  / standalone mode: write every non-ignored table down, clear it, and tell the hdbs to reload.
  / attributes are captured across ALL root tables and put back afterwards, as legacy does (rdb.q:104,
  / rdb.q:115) - the 0# clear in savetable discards them, and a gateway querying the fresh day would
  / otherwise get an unindexed table for the rest of the day
  t:tables[`.];
  atts:t!grabattrs each t;
  writedown[.z.m.hdbdir;date];
  restoretimeout[];
  reapplyattrs'[key atts;value atts];
  rmdtfromgetpar[date];
  runpostreplay[date];
  notifyhdbs[date];
  .z.m.loginfo[`endofday;"end of day complete for partition ",string date];
  };

endofday:{[date]
  / the tickerplant's end-of-day broadcast, published at root (and as .u.end) by init. di.pubsub sends
  / (`endofday;date), which the default .z.ps applies as endofday[date].
  / UNARY, where TorQ's is endofday[date;processdata] - legacy never references processdata anywhere in
  / the function body (rdb.q:85-126), and the shipped .u.end alias passes ()!() for it, so the second
  / parameter carries no information. a binary function here would silently become a PROJECTION under
  / di.pubsub's one-argument broadcast and the roll would never happen
  requireinit[`endofday];
  .z.m.rdbpartition:.z.m.rdbpartition,date+1;
  logpartition[];
  $[.z.m.reloadenabled;deferwritedown[];savecycle[date]];
  };

/ ============================================================
/ reload - the wdb's entry point
/ ============================================================

dropfirstnrows:{[t;n]
  / drop the prior day from a root table, leaving the ticks that have arrived since the roll -
  / TorQ rdb.q:154-160. protected per table so one failure does not abandon the rest.
  / RETURNS a success flag, which legacy does not: reload has to know WHICH tables were actually
  / dropped so it only clears those from the snapshot. without it a failed drop still gets its count
  / zeroed and the prior day is stranded in memory with nothing left to retry against
  .z.m.loginfo[`dropfirstnrows;"dropping first ",(string n)," rows from ",(string t),
    ". current table count is : ",string count value t];
  ok:.[{@[`.;x;y _];1b};(t;n);
    {[t;n;e] .z.m.logerr[`dropfirstnrows;"failed to drop first ",(string n)," rows from ",
      (string t),". the error was : ",e]; :0b}[t;n]];
  .z.m.loginfo[`dropfirstnrows;(string t)," now has ",(string count value t)," rows."];
  :ok;
  };

rungc:{[]
  / TorQ calls .gc.run after the drop (rdb.q:140). di.dbwrite already collects inside savedown, so this
  / is the one collection this module still owns and the one the `gc` config key gates
  .z.m.loginfo[`gc;"running garbage collection"];
  r:.Q.gc[];
  .z.m.loginfo[`gc;"garbage collection returned ",(string `long$r%1048576),"MB"];
  };

reload:{[date]
  / called BY THE WDB over ipc once it has persisted the prior day - published at root by init.
  / drops exactly the rows this rdb held at the roll (the deferwritedown snapshot), keeping everything
  / that has arrived since, then puts the attributes back and clears the snapshot so a repeat call is a
  / no-op. TorQ rdb.q:128-146.
  / NB this walks SUBTABLES, where endofday walks tables[`.]. that asymmetry is legacy's: a table this
  / process was never subscribed to was not fed by the tickerplant, so the wdb has not persisted it and
  / dropping rows from it would destroy data nothing else holds
  requirestart[`reload];
  .z.m.loginfo[`reload;"reload command has been called remotely"];
  t:.z.m.subtables except .z.m.ignorelist;
  atts:t!grabattrs each t;
  dropped:(),dropfirstnrows'[t;0^.z.m.eodtabcount t];
  rmdtfromgetpar[date];
  reapplyattrs'[key atts;value atts];
  if[.z.m.gc;rungc[]];
  / zero rather than delete, so a second reload drops nothing instead of dropping the day again.
  / only the tables that ACTUALLY dropped are cleared - a table whose drop threw keeps its count, so
  / a second reload[date] retries it rather than stranding the prior day in memory permanently with
  / no record of how much of it to remove
  .z.m.eodtabcount:@[.z.m.eodtabcount;t where dropped;:;0];
  if[not all dropped;
    .z.m.logwarn[`reload;"kept the eod snapshot for ",(", " sv string t where not dropped),
      " - the drop failed, call reload again once the cause is fixed"]];
  restoretimeout[];
  .z.m.loginfo[`reload;"finished reloading rdb"];
  };

/ ============================================================
/ remaining api
/ ============================================================

endofperiod:{[currp;nextp;data]
  / the tickerplant's intraday period roll, published at root by init - the port of TorQ's
  / code/rdb/endofperiod.q. log-only, as legacy is: an rdb has nothing to do at a period boundary, but
  / the message has to land somewhere or it surfaces as an unhandled async message.
  / TERNARY, matching legacy's producer: TorQ's code/common/pubsub.q:19 broadcasts
  / (`endofperiod;currentperiod;nextperiod;data).
  / di.pubsub's callendofperiod used to broadcast only (`endofperiod;x), which left this function
  / partially applied: q returned a PROJECTION (measured: type 104h) instead of running it, so nothing
  / logged and nothing threw. Keeping this ternary rather than narrowing it to fit the broken
  / broadcaster was the right call - di.pubsub is now ternary too and the two match. see rdb.md
  requireinit[`endofperiod];
  .z.m.loginfo[`endofperiod;"received endofperiod. currentperiod, nextperiod and data are ",
    (string currp),", ",(string nextp),", ",.Q.s1 data];
  };

moveandclear:{[fromns;tons;tab]
  / move a table's definition out of one namespace into another and delete the original - TorQ's
  / code/rdb/rdbstandard.q, registered as public api in code/rdb/apidetails.q. its documented use is
  / getting heartbeat and logmsg out of the top level before a save down.
  / NB legacy stores 0# of the table, i.e. the SCHEMA only, and then deletes the original - so the rows
  / do not survive the move. that is faithfully preserved rather than "fixed": changing it would change
  / what a shipped, publicly-registered api does. see rdb.md
  / NB the delete is the plain functional form ![namespace;();0b;enlist name], not legacy's
  / eval(!;enlist fromns;();0b;enlist enlist tab). the two are the same operation: legacy is building
  / a PARSE TREE, where a literal symbol has to be enlisted, and then evaluating it. applied directly
  / the extra enlists - and the eval - are not needed
  requireinit[`moveandclear];
  if[not tab in key fromns;:()];
  set[` sv (tons;tab);0#fromns tab];
  ![fromns;();0b;enlist tab];
  .z.m.loginfo[`moveandclear;"moved ",(string tab)," from ",(string fromns)," to ",string tons];
  };

status:{[]
  / a snapshot of how this rdb is wired and what it currently holds. the readiness check legacy spells
  / .rdb.notpconnected[] (rdb.q:202) is the `subscribed key, answered by di.subscriptions rather than
  / by reading its registry from outside
  requireinit[`status];
  / resubscribeenabled is reported alongside `subscribed` deliberately: the pair is what an operator
  / needs to read to tell "the feed is down and something is retrying it" from "the feed is down and
  / nothing is"
  / NB the key vector is PARENTHESISED. `!` binds tighter than `,`, so an unbracketed continuation
  / would parse as syms,(syms!values) and throw 'length
  :(`started`subscribed`resubscribeenabled`subtables`partition`hdbdir`reloadenabled`savetables,
    `onlyclearsaved`ignorelist)!
   (.z.m.started;
    $[.z.m.started;@[subscriptions.subscribed;::;{[e] :0b}];0b];
    .z.m.resubscribeenabled;
    .z.m.subtables;
    .z.m.rdbpartition;
    .z.m.hdbdir;
    .z.m.reloadenabled;
    .z.m.savetables;
    .z.m.onlyclearsaved;
    .z.m.ignorelist);
  };

/ ============================================================
/ api metadata
/ ============================================================

getapimeta:{[]
  / one row per CALLABLE export, for di.torq to register with di.api. init and getapimeta are omitted
  / as framework plumbing. names are bare; di.torq applies the process-wide qualification
  :flip `name`public`descrip`params`return!flip(
    (`version;      1b; "module version string";
       "[]";                                              "string: version");
    (`start;        1b; "connect to the tickerplant, subscribe and replay the day's log";
       "[]";                                              "null");
    (`teardown;     1b; "remove the root entry points and the timeout job installed by init and start";
       "[]";                                              "null");
    (`endofday;     1b; "end of day roll - save and clear the tables, or snapshot counts when a wdb owns the writedown";
       "[date: partition being rolled]";                  "null");
    (`reload;       1b; "called by the wdb once it has persisted the prior day - drop exactly the rows held at the roll";
       "[date: partition the wdb persisted]";             "null");
    (`endofperiod;  1b; "intraday period roll notification from the tickerplant - logged only";
       "[timestamp: current period; timestamp: next period; dict: process data]"; "null");
    (`getpartition; 1b; "the partition date(s) this rdb currently holds, for gateway routing";
       "[]";                                              "date list: partitions held");
    (`moveandclear; 1b; "move a table's schema to another namespace and delete the original";
       "[symbol: source namespace; symbol: target namespace; symbol: table]"; "null");
    (`status;       1b; "how this rdb is wired and what it currently holds";
       "[]";                                              "dict: started, subscribed, resubscribeenabled, subtables, partition and the eod policy"));
  };
