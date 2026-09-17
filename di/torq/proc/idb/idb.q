/ di.torq.proc.idb - intraday database process type. Mounts the WDB's *working* directory (the
/ same `savedir` the wdb writes/appends into during the day, before EOD sort+move into the
/ hdb - see di.torq.proc.wdb) so queries can see today's not-yet-persisted-to-hdb data intraday.
/ ---
/ v1 is a minimal, di.torq.proc.hdb-shaped mount + remount: di.torq.proc.idb only exposes a
/ remotely-triggerable `.idb.reload[]`, same shape as di.torq.proc.hdb's `.hdb.reload[]` -
/ something else has to call it after data changes on disk. idb itself never polls or pushes;
/ that something else is the wdb, which calls `.idb.reload[]` on every idbtypes connection two
/ ways - after any intraday flush that actually wrote something (unconditional), and again at
/ EOD if `idb` is opted into `reloadorder` (see di.torq.proc.wdb's wdb.q/wdb.md).
/ ---
/ Unlike the hdb (one fixed dir, mounted once and reloaded in place), the idb re-derives
/ WHICH date directory to mount on every reload: the wdb's savedir only ever holds the
/ current day's data (older days get moved into the hdb and the dir removed - see
/ di.torq.proc.wdb's movetohdb/endofday), so "today" can change under a long-lived idb process.
/ A fixed `partition` config override is supported so tests (and any point-in-time
/ inspection of a specific day) aren't at the mercy of wall-clock `.z.d`.
/ ---
/ The wdb enumerates every flushed table against ITS hdbdir, not against savedir (see
/ di.torq.proc.wdb's flushtable, `.Q.en[.z.m.hdbdir;...]`) - live, on every flush, not just at
/ EOD (`.Q.en` extends the domain AND rewrites hdbdir/sym on disk whenever it sees a symbol
/ that domain doesn't already have). So the mounted working-partition tables' symbol columns
/ are enumerated (foreign-keyed) against that SAME hdbdir/sym, not anything under savedir -
/ idb needs `hdbdir` as its own config, purely to load that file into its own session's root
/ `sym`, independently of mounting savedir. Without it, `` `sym `` never exists in the idb's
/ session and a symbol column reads back as raw enum indices instead of symbols.

/ base dir: runtime DATA lives under TORQXDATAHOME (falls back to TORQXAPPHOME) - the idb
/ mounts the wdb's working DATA dir, not code/config, same reasoning as di.torq.proc.hdb.
datahome:{$[count h:getenv[`TORQXDATAHOME];h;getenv[`TORQXAPPHOME]]}

/ resolve a possibly-relative savedir/hdbdir setting to an absolute path STRING (no leading
/ `:`), both always against datahome[] (idb has no apphome-relative config, unlike the wdb's
/ sortcsv, so unlike di.torq.proc.wdb's resolvedir this doesn't need a `base` parameter).
/ Mirrors di.torq.proc.wdb's resolvedir's BODY, NOT di.torq.proc.hdb's - the wdb's own
/ savedir/hdbdir TOML values arrive as a plain string with no leading colon (e.g. "wdb"),
/ unlike di.torq.proc.hdb's `dir` convention; since idb's savedir/hdbdir must resolve to the
/ SAME absolute paths as the wdb's, it has to strip a leading colon if present rather than
/ assume one, to handle both a `.q` settings symbol (`:wdb) and a `.toml` string ("wdb") the
/ same way the wdb itself does.
resolvedatadir:{[dir]
  dir:$[10h=abs type dir;dir;string dir];
  dir:$[(0<count dir) and ":"=first dir;1_dir;dir];
  $[dir like "/*";dir;datahome[],"/",dir]
  }

/ which date to mount: the fixed override if configured, else today - evaluated fresh on
/ every call so a reload after midnight naturally picks up the new day without a restart.
currentpartition:{[] $[.z.m.fixedpartition;.z.m.partition;.z.d]}

/ the specific date dir under savedir to mount, e.g. <savedir>/2026.07.09
partitiondir:{[] `$":",.z.m.savedir,"/",string currentpartition[]}

/ the hdb's sym file - a single fixed path, unlike partitiondir[] (not partition-scoped: the
/ wdb enumerates every day's flushes against the same hdbdir/sym, it never rolls per-date).
symfile:{[] `$":",.z.m.hdbdir,"/sym"}

/ size of the sym file as at the last load, as legacy TorQ's .idb.symsize. 0 is also what a
/ missing file stats as, so a sym file appearing for the first time reads as changed.
symsize:0

/ legacy TorQ's symfilehaschanged. Size, not mtime: .Q.en only ever appends.
/ hcount is trapped where legacy calls it bare - legacy's idb blocks on a wdb handshake so the
/ file always exists by now; this one is config-driven and tolerates it missing.
symfilehaschanged:{[]
  .z.m.symsize<>@[hcount;symfile[];0]
  }

/ legacy TorQ's `load symfilepath` - it names the variable after the file, so it sets root `sym`
/ even from inside a use-loaded module (verified). REPLACES rather than merges: the file is the
/ enumeration domain and the on-disk columns are positions in it, so root sym must match its order
/ exactly - a union against a reordered sym resolves every symbol column to the wrong value.
readsym:{[f]
  load f;
  .z.m.log[`info][`loadsym;"loaded sym domain (",(string count get `sym),") from ",1_string f];
  .z.m.symsize:@[hcount;f;0];
  }

/ force-load the sym domain; the caller decides whether to skip, as legacy splits loaddb from
/ intradayreload. A missing file is logged and survived - symsize stays 0 so the next reload
/ picks it up once a wdb has flushed.
loadsym:{[]
  f:symfile[];
  .z.m.log[`info][`loadsym;"loading the sym file from ",1_string f];
  @[readsym;f;{[e] .z.m.log[`error][`loadsym;"failed to load sym file: ",e," - symbol columns may not resolve"]}];
  }

/ mount (or remount) whatever partitiondir[] currently points at. The dir can legitimately
/ not exist yet - right after the wdb's EOD move (which rm -rf's the old day's now-empty
/ working dir) and before the new day's first intraday flush creates it again, there is
/ nothing on disk to mount. Rather than let `system "l"` throw and crash the process (or
/ leave init half-finished with no published .idb.reload[]), log a warning and leave
/ whatever is already loaded in place - the next reload[] (once the wdb has flushed
/ something for the new day) will pick it up.
domount:{[]
  dir:partitiondir[];
  $[count key dir;
    [system "l ",1_string dir; .z.m.log[`info][`domount;"loaded tables: ",", " sv string tables[]]];
    .z.m.log[`warn][`domount;"no working partition at ",(1_string dir)," yet - nothing to mount"]];
  }

reload:{[]
  / legacy TorQ's intradayreload, which its root-level `reload` aliases. An unchanged file is
  / silent. domount[] is deliberately NOT gated: legacy's wdb pre-creates every table dir
  / (filldb), so only a new partition can appear and its partitioncounthaschanged[] suffices.
  / Ours creates a table dir on its first flush, and a new table is invisible without a remount.
  .z.m.log[`info][`reload;"reloading idb from ",string partitiondir[]];
  if[symfilehaschanged[];loadsym[]];
  domount[];
  }

init:{[config;deps]
  if[not `log in key deps;'"di.torq.proc.idb: log dependency is required - see di.util.log"];
  .z.m.log:deps`log;
  if[not `savedir in key config;'"di.torq.proc.idb: savedir is required - the wdb's working directory (see di.torq.proc.wdb's savedir config)"];
  .z.m.savedir:resolvedatadir config`savedir;
  if[not `hdbdir in key config;'"di.torq.proc.idb: hdbdir is required - the hdb directory the wdb enumerates symbols against (see di.torq.proc.wdb's hdbdir config)"];
  .z.m.hdbdir:resolvedatadir config`hdbdir;
  .z.m.fixedpartition:`partition in key config;
  if[.z.m.fixedpartition;.z.m.partition:$[-14h=type config`partition;config`partition;"D"$config`partition]];
  .z.m.log[`info][`init;"mounting idb from ",string partitiondir[]];
  / force-loaded, and symsize cleared first: a size recorded against a previous init's hdbdir says
  / nothing about this file, and readsym only records on success so a failed load leaves it stale
  .z.m.symsize:0;
  loadsym[];
  domount[];
  / publish the IPC-callable surface at a real root-level name - use-loading this file
  / compiles it into a private namespace (see di.torq.proc.hdb.init's identical note: a remote
  / `.idb.reload[]` call would otherwise hit an undefined-function error).
  set[`.idb.reload;reload];
  }
