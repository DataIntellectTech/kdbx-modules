/ the historical database: mount a partitioned database directory and expose a remotely-triggerable
/ reload, so a process that has just persisted a new partition can make this one pick it up without a
/ restart.
/ ported from TorQ's code/hdb/hdbstandard.q - the whole of it, two functions - with the process
/ defaults from config/settings/hdb.q. see hdb.md for scope, divergences and design rationale.
/ the version lives in the VERSION file and is read by init.q
/ ROOT-NAMESPACE RULES (the same ones every process-tier module has hit). a source-level bare
/ identifier in module code is rewritten at load to this module's private namespace, so it can never
/ reach root. therefore:
/   - the root table list is tables[`.], never a bare tables[]
/   - the root entry point (reload) is installed with an explicit @[`.;...], never a bare assignment
/   - system"l ..." is a RUNTIME system call and is unaffected by the rewrite - it mounts into root,
/     which is exactly what a queryable hdb needs
/ RELOAD IS UNARY AND LIVES AT BARE ROOT. this is the one decision the module turns on, so it is
/ recorded here as well as in hdb.md. four independent producers agree that an hdb reload is a date
/ sent to a bare root `reload`:
/   TorQ code/processes/rdb.q:77   hdbmessage:{[d](`reload;d)} - async, applied by the default .z.ps
/   TorQ code/processes/wdb.q:479  reloadfunc:     @[{(1b;`. `reload x)};d;...] - async
/   TorQ code/processes/wdb.q:482  syncreloadfunc: @[h;({(1b;`reload x)};d);...] - sync
/   di.rdb rdb.q:947               hdbmessage:{[date] :(`reload;date)} via di.asyncutil.postback
/ TorqX's di/hdb/hdb.q instead ships reload:{[]...} published as .hdb.reload, matching NONE of them.
/ building it that way would have been silently incompatible with the di.rdb already in review, and
/ silently is the operative word: a niladic function called with an extra argument does NOT throw
/ 'rank, it discards the argument and returns normally (measured on KDB-X 0.1.2/2025.11.17). every
/ roll would have logged a successful reload having thrown the date away, with nothing on either side
/ to say so - a quieter failure than the crash that was originally predicted, and a worse one.

/ ============================================================
/ internal helpers - config coercion
/ ============================================================

ashsym:{[x]
  / normalise a directory setting to an hsym, accepting `:hdb, `hdb, ":hdb" or "hdb". lifted from
  / di.rdb rdb.q:51-55 rather than ported from TorqX's datahome/resolvedir, which joins a relative
  / path onto TORQXDATAHOME/TORQXAPPHOME - environment variables specific to TorqX's own sample-app
  / deployment and established nowhere in kdbx-modules. config values arrive as symbols from a .q
  / settings file and as strings from a .toml one, so both shapes are accepted here
  s:$[10h=abs type x;(),x;string x];
  :hsym `$$[(0<count s) and ":"=first s;1_s;s];
  };

/ ============================================================
/ internal helpers - path portability
/ ============================================================

requirenospace:{[p]
  / kdb+ cannot load a path containing a space AT ALL: \l throws a bare 'nyi on one, and no escaping
  / form avoids it - bare, "quoted" and back\ slashed all throw, while the identical database without
  / the space loads (measured, control included). so this is not a limitation to work around but one
  / to REPORT, at configuration time and with the reason, rather than as an unexplained 'nyi at start
  / or - worse - at the first reload. it matters most on windows, where "C:/Program Files/..." and a
  / user directory containing a space are entirely ordinary.
  if[any " "=p;
    '"di.hdb: hdbdir must not contain a space - kdb+ cannot load such a path (\\l throws 'nyi, and ",
      "quoting or escaping does not help); got: ",p];
  };

/ load-time constant, the same test di.os.iswindows uses. these modules ship to clients on whatever
/ platform they run, so nothing here may assume POSIX
iswindows:.z.o in `w32`w64;

isabspath:{[win;p]
  / is a bare path string (no leading colon) already absolute? asked PLATFORM-EXPLICITLY rather than
  / by a leading-slash test, because what "absolute" MEANS differs: on windows it is a drive letter
  / ("c:/data") or a UNC share ("//host/share"), neither of which starts with a slash. a POSIX-only
  / test resolved c:/data/hdb to <cwd>/c:/data/hdb - a plausible-looking directory nobody asked for,
  / which is precisely the silent wrong mount this module exists to prevent.
  / the platform is a PARAMETER rather than read from iswindows in here, so the windows branch can be
  / exercised from a linux box - that is the only way this code is tested at all before a client on
  / windows runs it, and untestable portability code is portability code that does not work
  if[0=count p;:0b];
  if[not win;:"/"=first p];
  / leading / or \ - a POSIX-style root, or a UNC share
  if[(first p) in "/\\";:1b];
  / a drive letter: exactly "<letter>:" followed by a separator
  :$[2<count p;(":"=p 1) and p[2] in "/\\";0b];
  };

resolvepath:{[win;cwd;p]
  / normalise separators and pin a relative path to cwd, producing the string this module mounts.
  / a q hsym is forward-slash on EVERY platform (`:c:/data/db is how kdb+ names a windows path), so
  / backslashes are converted rather than carried through - and system"cd" hands back backslashes on
  / windows, so the working directory needs the same treatment before anything is joined to it.
  / cwd is a PARAMETER for the same testability reason as win above.
  / deliberately does NOT canonicalise "." / ".." / duplicate separators the way di.os.abspath does:
  / mounting does not need it (q's \l resolves them itself), and this module is not the place to
  / reimplement a path library. di.os is where that belongs - see hdb.md for why there is no edge to it
  if[win;p:ssr[p;"\\";"/"]];
  if[isabspath[win;p];:p];
  :$[win;ssr[cwd;"\\";"/"];cwd],"/",p;
  };

/ ============================================================
/ internal helpers - lifecycle and errors
/ ============================================================

initialised:{[]
  / has init run? a direct (module-rewritten) reference detects prior setup without touching root.
  / hdbdir is deliberately given NO module-level default - its only value comes from init, so this
  / probe cannot be fooled by a load-time constant of the same name
  :@[{.z.m.hdbdir;1b};::;{[e] :0b}];
  };

requireinit:{[ctx]
  / every exported function except init depends on init having wired the logger and resolved hdbdir.
  / there is no default logger, so without this an early call dies with a bare 'type instead of a
  / usable message. TorqX's hdb.q has no such guard - calling its reload[] before init[] dies on an
  / unbound .z.m.dir, unlogged
  if[not initialised[];
    '"di.hdb: ",string[ctx],": init must be called before any other function"];
  };

raiseerror:{[ctx;msg]
  / log an error under ctx then signal it, so a failure is observable in the log and not only as a
  / throw. init's own dependency validation is the one exception - the logger is not wired yet.
  / this earns its place here more than in most modules. di.asyncutil.postback wraps the remote
  / evaluation of (`reload;date) in its own error trap and hands the message back to di.rdb as an
  / opaque "error: server fail: ..." string (asyncutil.q:29-30), which reloadreply then logs; TorQ
  / wdb.q:482's syncreloadfunc captures it the same way. so the throw IS seen by the caller - what
  / raiseerror adds is that what the caller sees names the module, the function and the path
  .z.m.logerr[ctx;msg];
  '"di.hdb: ",string[ctx],": ",msg;
  };

/ ============================================================
/ root entry point
/ ============================================================

publishroot:{[nm;f]
  / internal - publish ONE root entry point, warning first when the name already holds something that
  / is neither the function about to be installed nor the one this module installed last time.
  / comparing against rootinstalled as well as against f keeps a legitimate re-init quiet.
  / NB `reload` at root is genuinely contended: di.rdb publishes a unary root reload of its own
  / (rdb.q:209), so a process co-hosting both silently loses one without this warning. real TorQ
  / deployments always run the rdb and the hdb as separate processes, so this is documented rather
  / than designed around - changing the shared convention would mean editing di.rdb too. see hdb.md
  if[nm in key `.;
    cur:`. nm;
    if[not any (f;.z.m.rootinstalled nm)~\:cur;
      .z.m.logwarn[`installroot;"root ",(string nm)," was already bound to something di.hdb did not ",
        "install - replacing it. teardown will not give the previous binding back"]]];
  @[`.;nm;:;f];
  };

installroot:{[]
  / publish the entry point the rest of the stack calls this process on. `reload` is the whole of it:
  / an rdb or wdb that has just persisted a partition sends (`reload;date), which the default .z.ps
  / applies as reload[date].
  / record what was published so the NEXT install can tell "someone else took this name" from "this
  / module installed it last time"
  publishroot[`reload;reload];
  .z.m.rootinstalled:(enlist`reload)!enlist reload;
  };

dropifours:{[nm;f]
  / internal - delete a root name only if it still holds the function we installed there. a later
  / module that has taken over the name owns it now, and silently deleting its binding would be a
  / worse outcome than leaving ours behind
  if[not nm in key `.;:()];
  if[not f~`. nm;:()];
  ![`.;();0b;enlist nm];
  };

uninstallroot:{[]
  / internal - give back exactly what installroot published
  dropifours[`reload;reload];
  };

/ ============================================================
/ mounting
/ ============================================================

partitions:{[]
  / the partition values currently mounted, or an empty date list when the mounted database is not
  / partitioned. legacy hdbstandard.q:6 writes @[value;.Q.pf;.Q.PV], which THROWS on a flat (splayed)
  / database: .Q.PV is the third argument of a protected apply and so is evaluated eagerly, and
  / neither .Q.pf nor .Q.PV exists until a partitioned database has been loaded (measured - both
  / throw). nesting the fallback inside its own trap is what makes the guard actually guard
  :@[{value .Q.pf};::;{[e] :@[{value`.Q.PV};::;{[e2] :0#0Nd}]}];
  };

bumpfailures:{[]
  / internal - record one more consecutive reload failure. called ONLY from inside reload's error
  / trap, and called through a protected apply there, because this write can itself throw: under
  / multithreaded input (a negative -p) a remote reload runs on a secondary thread, where every
  / global write - including a module-local one - raises 'noupdate. measured: without that guard the
  / caller was handed "noupdate: `.m.di.0hdb `.z.m.consecutivefailures" INSTEAD of the real
  / "failed to mount ...: sys", i.e. a diagnostic counter destroyed the diagnosis it exists to serve
  .z.m.consecutivefailures:1+.z.m.consecutivefailures;
  };

multithreaded:{[]
  / internal - is this process using multithreaded input? a NEGATIVE port is how kdb+ enables it, and
  / system"p" reports the signed value (0i when no port is set). measured on KDB-X 0.1.2/2025.11.17
  :0>system"p";
  };

mount:{[ctx]
  / internal - the one place this module mounts the database, shared by start and reload so the two
  / cannot drift. legacy's system"l ." (hdbstandard.q:3) relies on the process's working directory
  / being the hdb root, which no use-loaded module can assume - hence the explicit resolved path.
  / PROTECTED and re-raised: an unprotected system"l" throws an OS message naming neither the module
  / nor the config key the path came from (measured: "/missing/path. OS reports: No such file or
  / directory"), and that bare string is exactly what a calling rdb sees back through postback
  p:1_string .z.m.hdbdir;
  @[system;"l ",p;{[c;path;e] raiseerror[c;"failed to mount ",path,": ",e]}[ctx;p;]];
  };

/ ============================================================
/ init and teardown
/ ============================================================

init:{[deps]
  / wire the injected log dependency (REQUIRED, never defaulted) and this module's one config key,
  / then publish the root entry point. ONE flat dict carrying dependency and config keys side by
  / side - the call shape di.torq wires every module with, and NOT TorqX's init[config;deps], which
  / di.torq cannot wire at all: q returns a PROJECTION for a two-argument function called with one
  / dict, so the module would do nothing and nothing would throw.
  / e.g. hdb.init[logging.logdict,enlist[`hdbdir]!enlist `:/data/hdb]
  / NB when passing more than one extra key, join logdict with ONE multi-key dict. joining it to a
  / chain of single-key dicts throws 'mismatch, because both value sides are tables.
  / NB init does NO i/o - it mounts nothing. that is start's job, so init can be unit-tested with no
  / database on disk. TorqX's init mounts inline, which makes it untestable without a real directory
  if[99h<>type deps;
    '"di.hdb: deps must be a dict of injectables + config, with a `log key and `hdbdir"];
  if[not `log in key deps;
    '"di.hdb: log dependency is required; pass `info`warn`error functions keyed on `log - see di.log"];
  if[99h<>type deps`log;
    '"di.hdb: log value must be a dict; pass `info`warn`error functions - see di.log"];
  / all three levels are genuinely called: info on mount, warn on a partition that did not arrive,
  / error through raiseerror - so all three are required rather than just the ones init itself uses
  if[not all `info`warn`error in key deps`log;
    '"di.hdb: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  / the three VALUES must be applicable, and this is checked BEFORE a single write lands. the keys
  / alone are not enough: a dict whose values are DATA passes every check above, whereupon init throws
  / from its OWN closing log call - by which point .z.m.loginfo and .z.m.hdbdir have already been
  / written. measured with `info`warn`error!(1;2;3): the module was left holding a poisoned logger and
  / the hdbdir of the very init that was rejected, and every later call - teardown included - died
  / with a bare 'length naming nothing. every callable type is >=100h and every data type is <=99h.
  / rank is deliberately NOT checked: a monadic kx.log instance is applicable and fails at the first
  / two-arg call site, which is the documented contract for every module - callers adapt, modules do not
  if[not all 100h<=type each deps[`log]`info`warn`error;
    '"di.hdb: log dict values must be binary {[ctx;msg]} functions; got types: ",
      (", " sv string type each deps[`log]`info`warn`error)," - see di.log"];
  / hdbdir is REQUIRED with NO default, a deliberate divergence from di.rdb (rdb.q:119 defaults it to
  / `:hdb). for an rdb a wrong hdbdir means WRITING to the wrong - probably empty - directory, which
  / is annoying and loud; for an hdb it means MOUNTING and then silently serving whatever happens to
  / be at that path, which is wrong query results that look like right ones. there is no default that
  / is safe to guess, so the module refuses to guess one
  if[not `hdbdir in key deps;
    '"di.hdb: hdbdir is required and has no default - name the database directory to mount"];
  / TYPE-check hdbdir BEFORE coercing it. ashsym stringifies whatever it is handed, and it fails two
  / different ways, both measured:
  /   SILENTLY WRONG - any atom that stringifies is accepted as a path. 42 becomes `:42, 2026.08.19
  /     becomes `:2026.08.19, 3.5 becomes `:3.5. this is the silent wrong-mount this module exists to
  /     prevent: a plausible-looking directory nobody asked for, which the process would then serve
  /   LOUD BUT ANONYMOUS - a list of strings, a symbol VECTOR or an enlisted symbol throws a bare
  /     'type from inside ashsym, naming neither the module nor the offending key
  / only a symbol atom or a string names one directory, so that is what is required here.
  / NB "one directory" is the operative phrase: ("a";"b") is NOT a list, it is the char vector "ab",
  / and is legitimately accepted as the relative path ab
  if[not (type deps`hdbdir) in -11 -10 10h;
    '"di.hdb: hdbdir must be a symbol or a string naming one directory; got: ",.Q.s1 deps`hdbdir];
  / coerce into a LOCAL and validate it before a single write lands, so a rejected re-init cannot
  / leave the module half-configured (di.rdb rdb.q:298-305)
  hdbroot:ashsym deps`hdbdir;
  / TRIM surrounding whitespace before anything is judged. a value arriving from a .toml or .q
  / settings file can be padded, and q's \l does tolerate a padded path (measured), so padding must
  / not be turned into a rejection by the interior-space guard below. done before the empty check,
  / since a value of all spaces trims to "" and is empty in every sense that matters here
  hdbroot:hsym `$trim 1_string hdbroot;
  / a null or empty hdbdir coerces to a bare ` (hsym`$"" is `), whose 1_string is "", and system"l "
  / then throws a bare 'nyi that names nothing at all (measured). rejected here, where the message can
  / name the key and show what was actually passed
  if[`~hdbroot;
    '"di.hdb: hdbdir must name a directory; got an empty value: ",.Q.s1 deps`hdbdir];
  / PIN A RELATIVE hdbdir to the working directory as it is NOW, at configuration time. mounting a
  / database CHDIRS the process into it - that is what q's \l does to a database directory (measured)
  / - so the same relative path resolves against a DIFFERENT directory on the second mount than on the
  / first. before this, a relative hdbdir gave a process that started perfectly and then failed EVERY
  / reload with "failed to mount hdb", i.e. an hdb that can never pick up a new partition, and the
  / failure appears only at the first roll. relative values are not rejected - ashsym accepts them by
  / design and di.rdb defaults to one (`:hdb) - they are resolved once, here, which also makes status[]
  / report an unambiguous absolute path.
  / system"cd" is the working directory as a string and tracks \cd, where getenv`PWD goes stale
  / (measured); it is q's own \cd handler, not a shell fork, and it is what di.os.pwd uses too
  hdbroot:hsym `$resolvepath[iswindows;system"cd";1_string hdbroot];
  / space check on the RESOLVED path, which covers both the configured value and a space inherited
  / from the working directory a relative value was pinned against
  requirenospace 1_string hdbroot;
  / is this the FIRST init in this process? read it BEFORE any write, because initialised[] probes
  / hdbdir, which is written below
  fresh:not initialised[];
  / has the DATABASE changed under a re-init? $[...] and not `and`, because the comparison reads the
  / OLD .z.m.hdbdir, which does not exist on a fresh init - `and` would evaluate it eagerly and throw.
  / re-applying the SAME config must not report a live hdb as unstarted, which is what `fresh` is for,
  / but pointing init at a DIFFERENT directory is not a re-apply: this module has definitively not
  / mounted that one. measured before this branch existed - status[] reported started:1b against the
  / new hdbdir while the process was still serving the old database.
  / EXACT string comparison, deliberately, and it CAN false-positive: on a case-insensitive volume
  / (windows, and macOS by default) `:/Data/HDB and `:/data/hdb are the same directory but compare
  / unequal, so a re-init that only changes the spelling reports a move that did not happen. left
  / exact because the two failure modes are not symmetric - a false positive costs a spurious warning
  / and an idempotent remount, whereas case-folding risks a false NEGATIVE that would report
  / started:1b against a database this process is not serving, which is the very defect this branch
  / was added to fix. folding on iswindows would also miss macOS (`m64), so it would not even be a
  / complete fix on its own terms. see hdb.md, known gaps
  moved:$[fresh;0b;not hdbroot~.z.m.hdbdir];
  .z.m.loginfo:(deps`log)`info;
  .z.m.logwarn:(deps`log)`warn;
  .z.m.logerr:(deps`log)`error;
  .z.m.hdbdir:hdbroot;
  / RUNTIME state is seeded on a FRESH init, and `started` is additionally cleared when the directory
  / moved, per above. rootinstalled is seeded here rather than at module load because publishroot reads
  / it on the FIRST install, before installroot has written it - and it is NOT cleared on a move, since
  / changing the database says nothing about who owns the root name
  if[fresh or moved;
    .z.m.started:0b];
  / OPERATIONAL HISTORY is seeded FRESH-ONLY, unlike `started` above. that asymmetry is the point: a
  / re-init - di.torq re-applying config, or an operator re-pointing hdbdir - must not erase the
  / record of when this process last actually worked. "when did the last successful mount happen" is
  / only useful if it outlives the config change that prompted someone to ask
  if[fresh;
    .z.m.rootinstalled:(`$())!();
    .z.m.laststart:0Np;
    .z.m.lastreload:0Np;
    .z.m.consecutivefailures:0];
  installroot[];
  .z.m.loginfo[`init;"di.hdb initialised - hdbdir ",1_string .z.m.hdbdir];
  / warned, not silent: the process is now configured for one database while still holding another.
  / q has no unmount, so the previously mounted tables keep answering queries - with the OLD data -
  / until start remounts, and .Q.pf keeps reporting the old partitions until then too
  if[moved;
    .z.m.logwarn[`init;"hdbdir changed - marked not started. the previously mounted database is still ",
      "in this process (q has no unmount) and keeps answering queries until start remounts"]];
  };

teardown:{[]
  / release the process-global binding init and start installed. module state is deliberately LEFT
  / INTACT so a shutdown path can still read hdbdir and the partition list.
  / NB this does NOT unload the database. q has no unmount, and dropping the mounted tables would
  / destroy the process's whole reason for existing - a torn-down di.hdb still answers queries, it
  / just no longer answers a remote reload. idempotent: dropifours checks the name is still ours
  / before deleting it, so a shutdown path may call this twice
  requireinit[`teardown];
  uninstallroot[];
  .z.m.started:0b;
  .z.m.loginfo[`teardown;"di.hdb root reload entry point removed - the mounted database is untouched"];
  };

/ ============================================================
/ api
/ ============================================================

start:{[]
  / mount the configured database and publish the reload entry point. split out of init deliberately:
  / init is pure configuration and can be unit-tested with no directory on disk, whereas this touches
  / the filesystem and can genuinely fail (a missing directory, a corrupt splayed table). weaker
  / motivation than di.rdb's split, which blocks on a tickerplant, but the split costs nothing and
  / buys the same no-real-database-needed testability
  requireinit[`start];
  / RE-PUBLISH the root entry point. init installs it, but teardown removes it and a caller may
  / legitimately tear down and start again without re-initialising - di.rdb rdb.q:688-695 measured
  / exactly that, leaving a process reporting itself started with no root entry point at all.
  / idempotent, so the ordinary init-then-start path is unaffected
  installroot[];
  mount[`start];
  / reached only on success - mount signals on failure. this is the "when did this last actually
  / work" an operator or a monitoring layer would otherwise have to grep the log for
  .z.m.laststart:.z.p;
  .z.m.started:1b;
  pv:partitions[];
  t:tables[`.];
  .z.m.loginfo[`start;"mounted ",(1_string .z.m.hdbdir)," - ",(string count pv)," partition(s), ",
    (string count t)," table(s): ",", " sv string t];
  / WARN ONCE, at the point this process commits to serving, if remote reload cannot work here.
  / under multithreaded input kdb+ runs each incoming message on a secondary thread, and system"l"
  / is forbidden there - it throws 'sys. that is a kdb+ restriction, not a module one: legacy's bare
  / system"l ." throws the identical 'sys (both measured over real IPC). serving queries is
  / unaffected, and a read-only hdb that is never told to reload is a legitimate deployment, so this
  / is a warning rather than a refusal. said HERE because the alternative is discovering it at the
  / first end-of-day roll, which is the failure mode this module has twice been hardened against
  if[multithreaded[];
    .z.m.logwarn[`start;"this process uses multithreaded input (port ",(string system"p"),") - a ",
      "remote reload CANNOT work in that mode: kdb+ forbids system\"l\" off the main thread and ",
      "throws 'sys. queries are unaffected. run with a positive port if this hdb must answer reload"]];
  };

reload:{[date]
  / remount the database, then check that the partition the caller just persisted actually arrived.
  / UNARY and published at BARE ROOT - see the header block for the four producers that agree on that
  / shape. TOLERANT OF A NULL date, because q applies a unary function called as reload[] with its
  / argument bound to (::) (measured), so a caller using TorqX's niladic .hdb.reload[] convention
  / still gets a real remount rather than a silent no-op.
  / legacy discards its argument entirely (hdbstandard.q's bracket-less reload:{...} accepts and
  / ignores extra arguments); that is an artefact of q's implicit-parameter rule, not a design, and
  / is not reproduced as though it were a feature
  requireinit[`reload];
  if[not (type date) in -14 101h;
    raiseerror[`reload;"date must be a date, or null for an unconditional remount; got: ",.Q.s1 date]];
  / is there a real partition to look for? the type alone does NOT answer that: 0Nd is itself type
  / -14h, so a bare type test let a null date reach the membership check below and produced the
  / warning "partition  is not present under ..." - naming no partition at all, because string 0Nd is
  / "" (measured). a null date carries the same information as no date, so it takes the same path.
  / `and` is safe here where it is not below: both operands are total, and null (::) is 1b, not a throw.
  / computed ONCE so the log message and the check cannot disagree about what was asked for
  havedate:(-14h=type date) and not null date;
  .z.m.loginfo[`reload;"reload command has been called remotely",
    $[havedate;" for partition ",string date;" with no partition supplied"]];
  / COUNT consecutive mount failures without changing anything the caller sees. mount has already
  / logged and signalled through raiseerror; this catches that signal, records it, and re-raises the
  / SAME string, so the "error: server fail: ..." di.rdb reads back through postback is unchanged.
  / counted on RELOAD only, never on start: a failed start is a configuration fault caught
  / immediately at deployment, whereas repeated reload failures are an operational degradation
  / pattern - an hdb that has silently stopped picking up new partitions. that is the escalation path
  / the partition-missing warning deliberately does not provide: the warning stays a warning, and
  / "this has failed N times running" becomes a fact a monitor can alert on instead of a log line to
  / count. see hdb.md
  / the bump is itself PROTECTED, so that recording a failure can never replace the report of it.
  / see bumpfailures - under multithreaded input the counter write throws 'noupdate and would mask
  / the mount error entirely. a diagnostic must never change what the caller is told
  @[mount;`reload;{[e] @[bumpfailures;::;{[e2] 0b}]; 'e}];
  / past this point the remount succeeded
  .z.m.lastreload:.z.p;
  .z.m.consecutivefailures:0;
  pv:partitions[];
  / the ONLY detector for the failure this module is least able to notice on its own: an hdbdir that
  / mounts SUCCESSFULLY and then silently serves the wrong data. a WARNING, not an error - an hdb
  / legitimately serving a subset of history, or one fronted by a writer that persisted elsewhere,
  / must not be broken by being told about a partition it does not carry
  / and it is only PERFORMABLE against a date-partitioned database. an int-, month- or sym-partitioned
  / hdb makes partitions[] a non-date vector, and `date in pv` then threw a bare 'type - unlogged,
  / outside raiseerror, and AFTER the remount had already succeeded, so a caller was told its reload
  / had failed when the database had in fact reloaded (measured against a .Q.pf=`int fixture).
  / both `and`s are on plain booleans and are safe eagerly; the NESTED if below is not optional, since
  / `havedate and not date in pv` would evaluate the membership test on a NULL date and die on it
  checkable:havedate and 14h=type pv;
  if[checkable;
    if[not date in pv;
      .z.m.logwarn[`reload;"partition ",(string date)," is not present under ",(1_string .z.m.hdbdir),
        " after the reload - check the writing process is pointed at the same database"]]];
  / the caller named a date this database cannot be asked about. reported at INFO, not warn: a
  / date-sending writer in front of an int-partitioned hdb is unusual, but it is not by itself wrong,
  / and the remount it asked for did happen
  if[havedate and not checkable;
    .z.m.loginfo[`reload;"mounted database is not date-partitioned - cannot confirm partition ",
      (string date)," arrived"]];
  .z.m.loginfo[`reload;"finished reloading hdb - ",(string count pv)," partition(s)"];
  };

getattributes:{[]
  / the process attributes a gateway caches for this hdb - legacy's .proc.getattributes
  / (hdbstandard.q:6), whose only caller was trackservers.q:137-141,178 remotely evaluating it on the
  / far side of every new connection.
  / NOT published at root as .proc.getattributes in v1: the new di.servers has no attributes column,
  / no getdetails, and never remote-evals anything on connect, so that mechanism has no equivalent
  / yet. di.rdb solves the same problem by PUSHING (`setattributes;...) to its gateways (rdb.q:998),
  / a path an hdb cannot use - config/settings/hdb.q sets .servers.CONNECTIONS:(), so it makes zero
  / outbound connections. so the data ships and the transport does not: di.torq can call this and
  / publish it under whatever process-identity convention it settles on, the same
  / declare-here/register-there layering getapimeta already uses. see hdb.md, known gaps
  requireinit[`getattributes];
  :`partition`tables!(partitions[];tables[`.]);
  };

status:{[]
  / a snapshot of how this hdb is wired, what it currently serves, and when it last worked. `started`
  / distinguishes an hdb that has been configured from one that has actually mounted - the two are
  / separate steps here.
  / the last three are OPERATIONAL HISTORY rather than current state: laststart and lastreload are
  / null until the corresponding operation has succeeded once, and consecutivefailures counts reload
  / mount failures since the last successful reload. they exist so "when did this last work" and "is
  / this degrading" are queryable facts rather than something only a log grep can answer
  requireinit[`status];
  :`started`hdbdir`partitions`tables`laststart`lastreload`consecutivefailures!
    (.z.m.started;.z.m.hdbdir;partitions[];tables[`.];
     .z.m.laststart;.z.m.lastreload;.z.m.consecutivefailures);
  };

/ ============================================================
/ api metadata
/ ============================================================

getapimeta:{[]
  / one row per CALLABLE export, for di.torq to register with di.api. init, getapimeta and version are
  / omitted as framework plumbing. names are bare; di.torq applies the process-wide qualification
  :flip `name`public`descrip`params`return!flip(
    (`start;         1b; "mount the configured hdb directory and publish the root reload entry point";
       "[]";                                       "null");
    (`teardown;      1b; "remove the root reload entry point - the mounted database is left in place";
       "[]";                                       "null");
    (`reload;        1b; "remount the database, then warn if the notified partition did not arrive";
       "[date: partition just persisted, or null]"; "null");
    (`getattributes; 1b; "the partition list and table list a gateway caches for this hdb";
       "[]";                                       "dict: partition, tables");
    (`status;        1b; "how this hdb is wired, what it serves, and when it last worked";
       "[]";
       "dict: started, hdbdir, partitions, tables, laststart, lastreload, consecutivefailures"));
  };
