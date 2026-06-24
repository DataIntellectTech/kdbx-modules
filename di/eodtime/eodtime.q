/ end-of-day time management - date resolution, roll scheduling and data timestamp adjustment

/ utc-equivalent timezone names - zero offset from utc so no timezone lookup required
utczones:`$("GMT";"UTC";"Etc/GMT");

/ default no-op logger - used when no log dep is injected
defaultlog:`info`warn`error!({[m]};{[m]};{[m]});

/ ============================================================
/ module state and defaults
/ ============================================================

/ roll timezone for eod scheduling - overwritten by init
rolltimezone:`$"GMT";

/ data timezone for incoming data timestamping - overwritten by init
datatimezone:`$"GMT";

/ offset from midnight for the eod roll - overwritten by init
rolltimeoffset:0D00:00:00.000;

/ current trading date in rolltimezone - set by init
d:0Nd;

/ utc timestamp of next eod roll - set by init
nextroll:0Wp;

/ utc offset for datatimezone data stamping - set by init
dailyadj:0D00:00:00.000;

/ ============================================================
/ internal helpers
/ ============================================================

setdeps:{[deps]
  / accept a bare kx.log instance (info/warn/error at top level) or a full deps dict keyed on `log
  / if absent or malformed falls back to no-op logger silently - log dep is optional for this module
  dv:$[99h=type deps;$[not `log in key deps;enlist[`log]!enlist deps;deps];deps];
  logval:$[99h=type dv;$[`log in key dv;dv`log;defaultlog];defaultlog];
  .z.m.log:$[99h=type logval;$[all `info`warn`error in key logval;logval;defaultlog];defaultlog];
  };

/ returns timespan offset from utc for rolltimezone at timestamp p
adjtime:{[p]
  / utc-equivalent timezones have zero offset
  if[rolltimezone in utczones;:0D];
  `timespan$tz.gmttolocal[rolltimezone;p]-p
  };

/ returns the date in rolltimezone for utc timestamp p
getday:{[p]"d"$(p+adjtime[p])-rolltimeoffset};

/ ============================================================
/ public api
/ ============================================================

/ recomputes utc offset for datatimezone at current time
/ call after an eod roll to get a fresh offset - important when datatimezone observes dst
getdailyadjustment:{
  / utc-equivalent timezones have zero offset
  if[datatimezone in utczones;:0D];
  `timespan$tz.gmttolocal[datatimezone;.z.p]-.z.p
  };

/ returns utc timestamp of next eod roll after utc timestamp p
getroll:{[p]
  / mod[z,1D] normalises the roll time to [0D,1D) to handle timezone offsets crossing midnight
  z:rolltimeoffset-adjtime[p];
  z:`timespan$(mod) . "j"$z,1D;
  / kdb-x 5.0: comparing timespan to timestamp checks against p's time-of-day component - true means roll has already passed
  ("d"$p)+$[z<=p;z+1D;z]
  };

/ state getters
getd:{d};
getnextroll:{nextroll};
getdailyadj:{dailyadj};

/ state setters
setnextroll:{.z.m.nextroll:x};
setdailyadj:{.z.m.dailyadj:x};
setd:{.z.m.d:x};

/ initialise module with config dictionary and optional log dependency
init:{[config;deps]
  / config: dict with optional keys `rolltimezone`datatimezone`rolltimeoffset
  /         pass (::) or ()!() to use all defaults matching torq eodtime.q behaviour
  / deps:   optional - kx.log instance or dict with `log -> `info`warn`error!(infofn;warnfn;errfn)
  /         if absent or malformed falls back to no-op logging silently
  / example:
  /   eodtime.init[`rolltimezone!enlist`$"Europe/London";kxlog.createLog[]]
  setdeps deps;
  cfg:$[99h=type config;config;()!()];
  .z.m.rolltimezone:$[`rolltimezone in key cfg;cfg`rolltimezone;`$"GMT"];
  .z.m.datatimezone:$[`datatimezone in key cfg;cfg`datatimezone;`$"GMT"];
  .z.m.rolltimeoffset:$[`rolltimeoffset in key cfg;cfg`rolltimeoffset;0D00:00:00.000];
  .z.m.dailyadj:getdailyadjustment[];
  .z.m.d:getday[.z.p];
  .z.m.nextroll:getroll[.z.p];
  .z.m.log[`info]["eodtime: initialised with rolltimezone=",string[rolltimezone]," datatimezone=",string[datatimezone]," rolltimeoffset=",string rolltimeoffset];
  };
