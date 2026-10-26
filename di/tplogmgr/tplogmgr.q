/ tickerplant log lifecycle: open, replay, append, roll; stateless, no init

/ log file handle <dir>/tp<date> for a dir string and date
logname:{[dir;date] `$":",dir,"/tp",string date}

/ open or create the date's log, replaying it through root `upd`; returns (handle;count)
/ signals on a corrupt log
open:{[dir;date]
  L:logname[dir;date];
  if[not type key L;               / log does not exist yet
    .[L;();:;()];                  / create an empty log file
    :(hopen L;0)];
  / count messages without executing; (good count;bytes read) if corrupt
  info:-11!(-2;L);
  if[1<count info;
    '"di.tplogmgr: corrupt log ",(1_string L)," - ",(string first info)," good message(s); truncate to that length and restart"];
  cnt:-11! L;                      / clean: replay through root `upd` exactly once
  (hopen L;cnt)
  }

/ append one message (typically (`upd;t;x)) to an open log handle
write:{[h;msg] h enlist msg;}

/ close the handle and open the next day's log; returns (handle;count)
roll:{[h;dir;olddate] hclose h; open[dir;olddate+1]}

/ replay a log through root `upd`, repairing first if corrupt; returns the replayed count
replay:{[logfile]
  info:-11!(-2;logfile);
  good:$[1<count info;repair logfile;logfile];
  -11! good
  }

/ replay the first n messages of a log through root `upd`, repairing first if corrupt
replayupto:{[logfile;n]
  info:-11!(-2;logfile);
  good:$[1<count info;repair logfile;logfile];
  -11!(n;good)
  }

/ di.tplog's corruption check and repair
check:{[logfile;lastmsgtoreplay] (use`di.tplog)[`check][logfile;lastmsgtoreplay]}
repair:{[logfile] (use`di.tplog)[`repair][logfile]}
