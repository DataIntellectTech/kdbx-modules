/ di.tplogmgr - tickerplant log lifecycle: create/open, replay-on-startup, append, roll.
/ These pieces are NOT in kdbx-modules: di.tplog covers only corruption
/ check/repair (which this module re-exports for the replay/RDB side). Ported from the
/ inline log handling in TorQ/code/processes/tickerplant.q (.u.ld / .u.endofday).
/ Stateless utility, like di.tplog - all state (dir, date, handle) is passed in;
/ there is no init and no module-local state to set up.

/ build the log filename handle for a dir (absolute path string) and date.
/ one file per date: <dir>/tp<date>, e.g. :/var/tplog/tp2026.07.13
logname:{[dir;date] `$":",dir,"/tp",string date}

/ open (creating if absent) the log for `date` under `dir`.
/ - absent: create an empty log, return (handle;0).
/ - present: replay via -11!, which executes the ROOT-LEVEL `upd` for each stored
/   (`upd;t;x) message, restoring in-memory state; return (handle;replayed-count).
/ A corrupt log is a FAIL-FAST error here - a tickerplant must not silently continue on
/ a bad log. The replay/RDB side uses `replay` (below), which repairs instead. The
/ caller must have a root-level `upd` defined before calling (di.proc.tickerplant publishes
/ one in its init, ahead of opening the log).
open:{[dir;date]
  L:logname[dir;date];
  if[not type key L;               / log does not exist yet
    .[L;();:;()];                  / create an empty log file
    :(hopen L;0)];
  / -11!(-2;L) streams the log to COUNT messages WITHOUT executing upd - so a corrupt
  / log is detected before any partial replay mutates state. Returns a single count for
  / a clean log, or (good-count;bytes-read) for a corrupt one.
  info:-11!(-2;L);
  if[1<count info;
    '"di.tplogmgr: corrupt log ",(1_string L)," - ",(string first info)," good message(s); truncate to that length and restart"];
  cnt:-11! L;                      / clean: replay through root `upd` exactly once
  (hopen L;cnt)
  }

/ append one message (typically (`upd;t;x)) to an open log handle
write:{[h;msg] h enlist msg;}

/ roll to the next day's log: close the current handle, open (create) the next day's.
/ returns the new (handle;count) - count is 0 for a freshly created log.
roll:{[h;dir;olddate] hclose h; open[dir;olddate+1]}

/ replay a log file through the root-level `upd`, repairing first if corrupt. Used by
/ consumers (e.g. the RDB on startup) - unlike `open` it recovers rather than failing.
/ Corruption is detected via the non-executing -11!(-2;...) streaming count FIRST, so a
/ good message before the corruption point is never replayed twice (a plain
/ @[-11!;...;handler] would partially replay before throwing, then replay again after
/ repair - double-processing). Returns the replayed message count.
replay:{[logfile]
  info:-11!(-2;logfile);
  good:$[1<count info;repair logfile;logfile];
  -11! good
  }

/ replay only the FIRST n messages of a log through root `upd` (repair-aware). Used by a
/ subscriber on startup: it replays exactly the messages the tickerplant had logged at
/ the instant it subscribed (the `rowcount` returned by di.proc.tickerplant.subdetails), so
/ live messages that arrive AFTER subscription - which are also delivered over the live
/ feed - are not double-processed. Whole-file `replay` would reprocess them. Returns the
/ replayed count. n>=good-count replays the whole (repaired) log.
replayupto:{[logfile;n]
  info:-11!(-2;logfile);
  good:$[1<count info;repair logfile;logfile];
  -11!(n;good)
  }

/ re-export di.tplog' corruption utilities so consumers have a single import
/ surface. use is idempotent so calling it per-invocation is cheap and sidesteps
/ module-local-dependency-variable resolution. NOTE: tplog' message signature is
/ hardcoded to the `trade` schema upstream - this limitation is inherited until that
/ module is generalised.
check:{[logfile;lastmsgtoreplay] (use`di.tplog)[`check][logfile;lastmsgtoreplay]}
repair:{[logfile] (use`di.tplog)[`repair][logfile]}
