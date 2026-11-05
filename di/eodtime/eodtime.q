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
getdailyadjustment:{
  / utc-equivalent timezones have zero offset
  if[datatimezone in utczones;:0D];
  / one clock read, so the offset is exact
  p:.z.p;
  `timespan$tz.gmttolocal[datatimezone;p]-p
  };

/ returns normalised roll time-of-day (utc) for the zone offset at timestamp p, wrapped to [0D,1D)
rolltod:{[p]`timespan$(mod) . "j"$(rolltimeoffset-adjtime[p]),1D};

/ returns utc timestamp of next eod roll after utc timestamp p
getroll:{[p]
  z:rolltod[p];
  / roll time already passed today: use tomorrow's roll time at tomorrow's offset
  $[z<=p;("d"$p+1D)+rolltod[p+1D];("d"$p)+z]
  };

/ state getters
getd:{d};
getnextroll:{nextroll};
getdailyadj:{dailyadj};
/ settings getters
getrolltimezone:{rolltimezone};
getdatatimezone:{datatimezone};
getrolltimeoffset:{rolltimeoffset};

/ state setters
setnextroll:{.z.m.nextroll:x};
setdailyadj:{.z.m.dailyadj:x};
setd:{.z.m.d:x};

init:{[deps]
  / validate deps, apply config and compute initial state
  / deps: `log (`info at minimum, {[c;m]}) plus optional `rolltimezone`datatimezone`rolltimeoffset
  if[99h<>type deps;
    '"di.eodtime: deps must be a dict with `log key"];
  if[not `log in key deps;
    '"di.eodtime: log dependency is required; pass at minimum `info!{[c;m]} keyed on `log"];
  if[99h<>type deps`log;
    '"di.eodtime: log value must be a dict; pass at minimum `info!{[c;m]}"];
  if[not `info in key deps`log;
    '"di.eodtime: log dict must have at minimum an `info key; got: ",(", " sv string key deps`log)];
  .z.m.loginfo:(deps`log)`info;
  .z.m.rolltimezone:$[`rolltimezone in key deps;deps`rolltimezone;`$"GMT"];
  .z.m.datatimezone:$[`datatimezone in key deps;deps`datatimezone;`$"GMT"];
  .z.m.rolltimeoffset:$[`rolltimeoffset in key deps;deps`rolltimeoffset;0D00:00:00.000];
  .z.m.dailyadj:getdailyadjustment[];
  .z.m.d:getday[.z.p];
  .z.m.nextroll:getroll[.z.p];
  .z.m.loginfo[`eodtime;"initialised with rolltimezone=",string[.z.m.rolltimezone]," datatimezone=",string[.z.m.datatimezone]," rolltimeoffset=",string .z.m.rolltimeoffset];
  };