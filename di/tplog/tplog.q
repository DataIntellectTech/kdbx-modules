/ di.tplog - tickerplant log lifecycle plus corruption check/repair, in one module.
/ lifecycle (open/write/roll/replay/replayupto/logname) is ported from the inline log handling
/ in TorQ/code/processes/tickerplant.q (.u.ld / .u.endofday); the byte-scanning check/repair
/ recovery is ported from TorQ/code/common/tplogutils.q. self-contained: no hard `use` deps.
/ log is an injected, required dependency (see init) - best-effort recovery is narrated so silent
/ message drops are observable. version is sourced from the VERSION file in init.q.

/ --- message-signature constants used by the byte-scan recovery (repairover) ---
/ these are geared to the (`upd;`trade;...) message shape, inherited from TorQ tplogutils; logs of
/ other table shapes are recovered only if their messages share this prefix (see known gaps in .md)
/ header template to rebuild a deserialisable message header
header:8#-8!(`upd;`trade;());
/ first bytes of a tp update message, the signature searched for in the raw log
updmsg:`char$10#8_-8!(`upd;`trade;());
/ default chunk to read (10mb)
chunk:10*1024*1024;
/ never let a single read exceed this
maxchunk:8*chunk;

init:{[deps]
  / wire the injected log dependency - required, no fallback. deps is a dict with a `log key holding
  / `info`warn`error!({[ctx;msg]};...) (extra levels like di.log's six are accepted and ignored).
  / examples:
  /   tp.init[(use`di.log)`logdict]                      / di.log.logdict is pre-shaped as `log!(...)
  /   tp.init[enlist[`log]!enlist `info`warn`error!(f;f;f)]
  / signalled with a plain ' (not raiseerror) - the logger is not yet wired while init runs.
  if[99h<>type deps;
    '"di.tplog: deps must be a dict with a `log key"];
  if[not `log in key deps;
    '"di.tplog: log dependency is required; pass `info`warn`error functions keyed on `log"];
  if[99h<>type deps`log;
    '"di.tplog: log value must be a dict of `info`warn`error functions"];
  if[not all `info`warn`error in key deps`log;
    '"di.tplog: log dict must have `info`warn`error keys; got: ",", " sv string key deps`log];
  .z.m.loginfo:deps[`log]`info;
  .z.m.logwarn:deps[`log]`warn;
  .z.m.logerr:deps[`log]`error;
  };

raiseerror:{[ctx;msg]
  / internal - log an error under ctx via the injected logger, then signal it, so a failure lands in
  / the log as well as being thrown. every post-init domain error routes through here.
  .z.m.logerr[ctx;msg];
  '"di.tplog: ",string[ctx],": ",msg;
  };

corruptp:{[logfile]
  / internal - true if the log is unreadable/corrupt. -11!(-2;...) is the NON-EXECUTING mode: on a
  / clean log it returns the message count without running upd, and on this kdb-x build it THROWS on
  / any corruption (classic kdb+ instead returns a (goodcount;bytes) pair). corruption is therefore
  / detected by trapping that throw. NB -11!(-1;...) also counts but EXECUTES upd, so is not used here.
  / does not execute upd and never signals.
  `corrupt~@[{-11!(-2;x);`ok};logfile;{`corrupt}]
  };

logname:{[dir;date]
  / build the log file handle for an absolute-path dir (string) and a date; one file per date,
  / <dir>/tp<date>, e.g. `:/var/tplog/tp2026.08.13
  :`$":",dir,"/tp",string date;
  };

open:{[dir;date]
  / open (creating if absent) the log for date under dir. absent: create empty, return (handle;0).
  / present: count with the non-executing -11!(-2;...) FIRST, so a corrupt log fails fast BEFORE any
  / partial replay mutates state (a tickerplant must not continue on a bad log - use replay to recover
  / instead). clean: replay through the root-level upd exactly once, return (handle;count).
  l:logname[dir;date];
  if[not type key l;
    .z.m.loginfo[`open;"creating new log ",1_string l];
    .[l;();:;()];
    :(hopen l;0)];
  cnt:@[{-11!(-2;x)};l;{[lf;e] raiseerror[`open;"corrupt log ",(1_string lf),": ",e," - use replay to recover"]}[l;]];
  .z.m.loginfo[`open;"replaying ",(string cnt)," message(s) from ",1_string l];
  -11! l;
  :(hopen l;cnt);
  };

write:{[h;msg]
  / append one message (typically (`upd;t;x)) to an open log handle
  h enlist msg;
  };

roll:{[h;dir;olddate]
  / roll to the next day's log: close the current handle, open (create) the olddate+1 log
  .z.m.loginfo[`roll;"rolling log for ",string olddate];
  hclose h;
  :open[dir;olddate+1];
  };

replay:{[logfile]
  / replay a log through the root-level upd, repairing first if corrupt (recovers rather than failing -
  / for consumers like an rdb on startup). corruption is checked with the non-executing corruptp FIRST,
  / so good messages before the corruption point are never replayed twice (a naive trap-and-retry would
  / partially replay before throwing, then replay again). returns the replayed message count.
  good:$[corruptp logfile;repair logfile;logfile];
  :-11! good;
  };

replayupto:{[logfile;n]
  / replay only the first n messages of a log through the root upd (repair-aware). for a subscriber on
  / startup replaying exactly its pre-subscription rowcount, so live messages that arrive after
  / subscription are not double-processed. n>=good-count replays the whole (repaired) log.
  good:$[corruptp logfile;repair logfile;logfile];
  :-11!(n;good);
  };

check:{[logfile;lastmsgtoreplay]
  / return logfile if it is usable as-is, else a repaired <logfile>.good. lastmsgtoreplay is the index
  / of the last message the caller intends to replay; it is retained for signature compatibility with
  / TorQ's .tplog.check, but on kdb-x the "corrupt yet enough good messages, skip repair" optimisation
  / is unavailable (-11! throws rather than returning a partial good-count), so any corruption repairs.
  .z.m.loginfo[`check;"checking ",(1_string logfile)," (caller replays up to index ",(string lastmsgtoreplay),")"];
  if[not corruptp logfile;
    .z.m.loginfo[`check;"log is clean - using as-is"];
    :logfile];
  .z.m.logwarn[`check;"log is corrupt - writing a repaired good log"];
  :repair logfile;
  };

repair:{[logfile]
  / scan a corrupt log in chunks and write every recoverable message to <logfile>.good, returning that
  / handle. best-effort: only messages that deserialise are kept, so unrecoverable messages are dropped.
  goodlog:`$string[logfile],".good";
  .z.m.loginfo[`repair;"writing recovered messages to ",1_string goodlog];
  goodlogh:hopen goodlog set ();
  repairover[logfile;goodlogh] over `start`size!(0j;chunk);
  hclose goodlogh;
  .z.m.loginfo[`repair;"finished repairing ",1_string logfile];
  :goodlog;
  };

repairover:{[logfile;goodlogh;d]
  / internal - one pass of the chunked byte-scan recovery, driven by `over` on a `start`size dict.
  / d has keys start (offset to read from) and size (bytes to read); returns the next d, or d itself
  / at eof to terminate the scan.
  / read <size> bytes from <start>
  x:read1 logfile,d`start`size;
  / find the start points of upd messages
  u:ss[`char$x;updmsg];
  if[not count u;
    / nothing in this block - stop at eof, else move on one chunk
    if[hcount[logfile]<=sum d`start`size;:d];
    :@[d;`start;+;d`size]];
  / split bytes into candidate messages
  m:u _ x;
  / message sizes as bytes
  mz:0x0 vs' `int$ 8+ms:count each m;
  / set each message size into the correct header bytes
  hd:@[header;7 6 5 4;:;] each mz;
  / try to deserialise each candidate; g is a list of (ok;value) pairs
  g:@[(1b;)@-9!;;(0b;)@] each hd,'m;
  / write the good messages to the good log
  goodlogh g[;1] where k:g[;0];
  if[not any k;
    / saw candidate(s) but none deserialised - give up past maxchunk, else read a bigger chunk
    if[maxchunk<=d`size;:@[d;`start`size;:;(sum d`start`size;chunk)]];
    :@[d;`size;*;2]];
  / advance to the end of the last good message
  ns:d[`start]+sums[ms] last where k;
  :@[d;`start`size;:;(ns;chunk)];
  };

getapimeta:{[]
  / this module's api metadata, one row per CALLABLE api function (NOT init/getapimeta/version - those
  / are plumbing di.torq reads by convention, never registered), for di.torq to collect and register
  / with di.api. names are bare; di.torq applies the process-wide qualification. one self-contained
  / (name;public;descrip;params;return) row per line - flip cols!flip rows.
  :flip `name`public`descrip`params`return!flip(
    (`logname;1b;"build the log file handle for a dir and date (<dir>/tp<date>, one file per date)";"[string dir; date date]";"symbol: log file handle");
    (`open;1b;"open a log (create if absent); replay a clean log through root upd, fail fast if corrupt";"[string dir; date date]";"(int handle; long count)");
    (`write;1b;"append one message (typically (`upd;t;x)) to an open log handle";"[int handle; any msg]";"null");
    (`roll;1b;"close the current handle and open (create) the next day's log";"[int handle; string dir; date olddate]";"(int handle; long count)");
    (`replay;1b;"replay a log through root upd, repairing first if corrupt (recover rather than fail)";"[symbol logfile]";"long: replayed message count");
    (`replayupto;1b;"replay only the first n messages of a log (repair-aware), for subscriber startup";"[symbol logfile; long n]";"long: replayed count");
    (`check;1b;"return the logfile if clean, else a repaired <logfile>.good";"[symbol logfile; long lastmsgtoreplay]";"symbol: usable log handle");
    (`repair;1b;"scan a corrupt log and write recoverable messages to <logfile>.good";"[symbol logfile]";"symbol: <logfile>.good handle"));
  };
