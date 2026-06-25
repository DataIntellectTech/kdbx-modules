/ end-of-day time management - date resolution, roll scheduling and data timestamp adjustment

/ utc-equivalent timezone names - zero offset from utc so no timezone lookup required
utczones:`$("GMT";"UTC";"Etc/GMT");

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

normlog:{[logdict]
  / detect kx.log instance by presence of kx.log-specific keys (getlvl, sinks, fmts)
  / kx.log functions are monadic - wrap each into binary {[c;m]} and embed context in the message
  / plain {[c;m]} log dicts (info`warn`error only) pass through unchanged
  $[any `getlvl`sinks`fmts in key logdict;
    `info`warn`error!(
      {[fn;c;m] fn[string[c],": ",m]}[logdict`info;];
      {[fn;c;m] fn[string[c],": ",m]}[logdict`warn;];
      {[fn;c;m] fn[string[c],": ",m]}[logdict`error;]);
    logdict]
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

init:{[deps]
  / initialise the eodtime module - validate deps, apply config, compute initial state
  / deps: dict containing `log (required) plus optional `rolltimezone, `datatimezone, `rolltimeoffset
  / log dep: at minimum `info!{[c;m]} - binary, c=context symbol, m=string
  / examples:
  /   eodtime.init[enlist[`log]!enlist logdep]
  /   eodtime.init[`log`rolltimezone!(logdep;`$"Europe/London")]
  if[99h<>type deps;
    '"di.eodtime: deps must be a dict with `log key"];
  if[not `log in key deps;
    '"di.eodtime: log dependency is required; pass at minimum `info!{[c;m]} keyed on `log"];
  if[99h<>type deps`log;
    '"di.eodtime: log value must be a dict; pass at minimum `info!{[c;m]}"];
  if[not `info in key deps`log;
    '"di.eodtime: log dict must have at minimum an `info key; got: ",(", " sv string key deps`log)];
  .z.m.log:normlog deps`log;
  .z.m.rolltimezone:$[`rolltimezone in key deps;deps`rolltimezone;`$"GMT"];
  .z.m.datatimezone:$[`datatimezone in key deps;deps`datatimezone;`$"GMT"];
  .z.m.rolltimeoffset:$[`rolltimeoffset in key deps;deps`rolltimeoffset;0D00:00:00.000];
  .z.m.dailyadj:getdailyadjustment[];
  .z.m.d:getday[.z.p];
  .z.m.nextroll:getroll[.z.p];
  .z.m.log[`info][`eodtime;"initialised with rolltimezone=",string[rolltimezone]," datatimezone=",string[datatimezone]," rolltimeoffset=",string rolltimeoffset];
  };