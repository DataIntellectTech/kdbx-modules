/ library for converting between and managing timezones

/ override variables to change internal logic
config.file:":::config/tzinfo"; / filepath of timezone data to be downloaded with utility script

/ read and format file for internal function reference
config.read:{
  tz:get hsym `$x;
  tz:delete from tz where gmtDateTime>=10170056837;
  tz:update gmtDateTime:12h$-946684800000000000+gmtDateTime*1000000000 from tz;
  tz:update gmtOffset:16h$gmtOffset*1000000000 from tz;
  tz:update localDateTime:gmtDateTime+gmtOffset from tz;
  tz:`gmtDateTime xasc tz;
  tz:update `g#timezoneID from tz;
  tz
  };

/ convert from local timestamp to gmt
gmttolocal:{[tz;ts]
  if[not all ((),tz:`$tz) in\: .z.m.zones;'`notValidTimezone];
  $[0>type ts;first;(::)]@exec gmtDateTime+gmtOffset from aj[`timezoneID`gmtDateTime;([]timezoneID:tz;gmtDateTime:ts,());.z.m.offsets]
  };

/ convert from gmt to local timestamp
localtogmt:{[tz;ts]
  if[not all ((),tz:`$tz) in\: .z.m.zones;'`notValidTimezone];
  $[0>type ts;first;(::)]@exec localDateTime-gmtOffset from aj[`timezoneID`localDateTime;([]timezoneID:tz;localDateTime:ts,());.z.m.offsets]
  };

/ convert between custom timestamps
convert:{[stz;dtz;ts].z.m.gmttolocal[dtz;.z.m.localtogmt[stz;ts]]};

/ init function to read in timezone source data
init:{
  .z.m.offsets:@[.z.m.config.read;x;{'`cantImportTimeZoneData}];
  .z.m.zones:exec distinct timezoneID from .z.m.offsets;
  };

init .z.m.config.file

export:([gmttolocal:gmttolocal;localtogmt:localtogmt;convert:convert;init:init])
