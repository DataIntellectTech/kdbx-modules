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

/ returns timespan offset from utc for datatimezone at current time
getdailyadjustment:{
  / utc-equivalent timezones have zero offset
  if[datatimezone in utczones;:0D];
  `timespan$tz.gmttolocal[datatimezone;.z.p]-.z.p
  };

/ returns the date in rolltimezone for utc timestamp p
getday:{[p]"d"$(p+adjtime[p])-rolltimeoffset};

/ returns utc timestamp of next eod roll after utc timestamp p
getroll:{[p]
  / mod[z,1D] normalises the roll time to [0D,1D) to handle timezone offsets crossing midnight
  z:rolltimeoffset-adjtime[p];
  z:`timespan$(mod) . "j"$z,1D;
  / kdb-x 5.0: comparing timespan to timestamp checks against p's time-of-day component - true means roll has already passed
  ("d"$p)+$[z<=p;z+1D;z]
  };

/ ============================================================
/ public api
/ ============================================================

/ state getters
getd:{d};
getnextroll:{nextroll};
getdailyadj:{dailyadj};

/ state setters
setnextroll:{.z.m.nextroll:x};
setdailyadj:{.z.m.dailyadj:x};
setd:{.z.m.d:x};

/ initialise module with config dictionary
init:{[config]
  / normalise config to dict and apply keys, falling back to defaults where not provided
  cfg:$[99h=type config;config;()!()];
  .z.m.rolltimezone:$[`rolltimezone in key cfg;cfg`rolltimezone;`$"GMT"];
  .z.m.datatimezone:$[`datatimezone in key cfg;cfg`datatimezone;`$"GMT"];
  .z.m.rolltimeoffset:$[`rolltimeoffset in key cfg;cfg`rolltimeoffset;0D00:00:00.000];
  .z.m.dailyadj:getdailyadjustment[];
  .z.m.d:getday[.z.p];
  .z.m.nextroll:getroll[.z.p];
  };
