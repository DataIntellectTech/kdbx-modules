/ tickerplant log utilities - open/append/roll/replay and corruption repair.
/ lifecycle ported from TorQ tickerplant.q (.u.ld/.u.endofday), repair from tplogutils.q.

/ (`upd;`trade;...) signature the byte-scan repair looks for - see the repair notes in the .md
header:8#-8!(`upd;`trade;());
updmsg:`char$10#8_-8!(`upd;`trade;());
chunk:10*1024*1024;
maxchunk:8*chunk;

init:{[deps]
  / deps`log: an `info`warn`error dict of {[ctx;msg]}, required. signalled plainly - no logger yet.
  if[99h<>type deps;'"di.tplog: deps must be a dict with a `log key"];
  if[not `log in key deps;'"di.tplog: log dependency is required"];
  if[99h<>type deps`log;'"di.tplog: log must be a dict of `info`warn`error functions"];
  if[not all `info`warn`error in key deps`log;
    '"di.tplog: log needs `info`warn`error, got ",", " sv string key deps`log];
  .z.m.loginfo:deps[`log]`info;
  .z.m.logwarn:deps[`log]`warn;
  .z.m.logerr:deps[`log]`error;
  };

raiseerror:{[ctx;msg]
  / log then signal, so the failure lands in the log too
  .z.m.logerr[ctx;msg];
  '"di.tplog: ",string[ctx],": ",msg;
  };

/ true if the log won't cleanly replay. -11!(-2) counts a clean log without running upd and throws
/ on corruption, so trap the throw. (-11!(-1) counts too but runs upd - don't use it here.)
corruptp:{[logfile] `corrupt~@[{-11!(-2;x);`ok};logfile;{`corrupt}]};

/ true if logfile names an existing directory rather than a file. `-11h=type logfile` (checked by
/ every caller below) only confirms the value is A symbol, not that it names a real log file - a
/ directory path passes that guard, and corruptp's own throw-catching then misreports it as
/ "corrupt" rather than "not a file". measured: `key` on a directory returns its listing (type 11h,
/ a symbol list), on a plain file returns the file's own name back (type -11h, a symbol atom), and
/ on a nonexistent path returns () (type 0h) - so 11h=type key f is a precise, portable directory
/ test with no filesystem shell-out
isdir:{[logfile] 11h=type key logfile};

logname:{[dir;date]
  / <dir>/tp<date>, one log file per date
  if[not 10h=type dir;raiseerror[`logname;"dir must be a string"]];
  if[not -14h=type date;raiseerror[`logname;"date must be a date"]];
  `$":",dir,"/tp",string date
  };

open:{[dir;date]
  / new log -> (handle;0); existing -> replay once through the root upd, returning (handle;count).
  / a corrupt log throws here rather than half-replaying - use replay to recover from one.
  l:logname[dir;date];
  if[not type key l;
    .z.m.loginfo[`open;"creating new log ",1_string l];
    .[l;();:;()];
    :(hopen l;0)];
  cnt:@[{-11!(-2;x)};l;{[lf;e] raiseerror[`open;"corrupt log ",(1_string lf),": ",e]}[l;]];
  .z.m.loginfo[`open;"replaying ",(string cnt)," messages from ",1_string l];
  -11! l;
  (hopen l;cnt)
  };

write:{[h;msg] h enlist msg;};

roll:{[h;dir;olddate]
  / close the current handle and open the next day's log
  if[not -6h=type h;raiseerror[`roll;"handle must be an int"]];
  if[not -14h=type olddate;raiseerror[`roll;"olddate must be a date"]];
  .z.m.loginfo[`roll;"rolling log for ",string olddate];
  hclose h;
  open[dir;olddate+1]
  };

replay:{[logfile]
  / repair if corrupt, then replay through the root upd. the non-executing corruptp check up front
  / means good messages are not replayed twice.
  if[not -11h=type logfile;raiseerror[`replay;"logfile must be a symbol"]];
  if[isdir logfile;raiseerror[`replay;"logfile is a directory, not a file: ",string logfile]];
  -11! $[corruptp logfile;repair logfile;logfile]
  };

replayupto:{[logfile;n]
  / replay only the first n messages - a subscriber replays up to the point it subscribed
  if[not -11h=type logfile;raiseerror[`replayupto;"logfile must be a symbol"]];
  if[not (type n) in -7 -6h;raiseerror[`replayupto;"n must be an int or long"]];
  if[isdir logfile;raiseerror[`replayupto;"logfile is a directory, not a file: ",string logfile]];
  -11!(n;$[corruptp logfile;repair logfile;logfile])
  };

check:{[logfile]
  / logfile if it is usable, else a repaired copy
  if[not -11h=type logfile;raiseerror[`check;"logfile must be a symbol"]];
  if[isdir logfile;raiseerror[`check;"logfile is a directory, not a file: ",string logfile]];
  if[not corruptp logfile;:logfile];
  .z.m.logwarn[`check;"corrupt log, repairing ",1_string logfile];
  repair logfile
  };

repair:{[logfile]
  / write every message that still deserialises to <logfile>.good
  if[not -11h=type logfile;raiseerror[`repair;"logfile must be a symbol"]];
  if[isdir logfile;raiseerror[`repair;"logfile is a directory, not a file: ",string logfile]];
  goodlog:`$string[logfile],".good";
  goodlogh:hopen goodlog set ();
  repairover[logfile;goodlogh] over `start`size!(0j;chunk);
  hclose goodlogh;
  .z.m.loginfo[`repair;"repaired ",(1_string logfile)," -> ",1_string goodlog];
  goodlog
  };

repairover:{[logfile;goodlogh;d]
  / one scan pass over a `start`size window; returns the next window, or d unchanged at eof
  x:read1 logfile,d`start`size;
  u:ss[`char$x;updmsg];
  if[not count u;
    if[hcount[logfile]<=sum d`start`size;:d];
    :@[d;`start;+;d`size]];
  m:u _ x;
  / rebuild each candidate's header with its true length, then try to deserialise it
  mz:0x0 vs' `int$ 8+ms:count each m;
  hd:@[header;7 6 5 4;:;] each mz;
  g:@[(1b;)@-9!;;(0b;)@] each hd,'m;
  goodlogh g[;1] where k:g[;0];
  if[not any k;
    / nothing readable in the window - grow it, or skip past it once we hit maxchunk
    if[maxchunk<=d`size;:@[d;`start`size;:;(sum d`start`size;chunk)]];
    :@[d;`size;*;2]];
  ns:d[`start]+sums[ms] last where k;
  @[d;`start`size;:;(ns;chunk)]
  };

getapimeta:{[]
  / callable api for di.torq to register with di.api (init/getapimeta/version are plumbing, omitted)
  flip `name`public`descrip`params`return!flip(
    (`logname;1b;"log file handle for a dir and date (<dir>/tp<date>)";"[string dir; date date]";"symbol");
    (`open;1b;"open/create a log, replaying an existing one; fail fast if corrupt";"[string dir; date date]";"(handle;count)");
    (`write;1b;"append a message to an open log handle";"[int handle; any msg]";"null");
    (`roll;1b;"close the handle and open the next day's log";"[int handle; string dir; date olddate]";"(handle;count)");
    (`replay;1b;"replay through the root upd, repairing first if corrupt";"[symbol logfile]";"long count");
    (`replayupto;1b;"replay the first n messages only";"[symbol logfile; long n]";"long count");
    (`check;1b;"logfile if usable, else a repaired copy";"[symbol logfile]";"symbol");
    (`repair;1b;"recover readable messages into <logfile>.good";"[symbol logfile]";"symbol"))
  };
