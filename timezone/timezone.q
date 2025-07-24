/ library for converting between and managing timezones

/ override variables to change internal logic
.timezone.config.file:"timezone/config/tzinfo"; / filepath of timezone data to be downloaded with utility script

/ read and format file for internal function reference
.timezone.config.read:{
  tz:get hsym `$.timezone.config.file;
  tz:delete from tz where gmtDateTime>=10170056837;
  tz:update gmtDateTime:12h$-946684800000000000+gmtDateTime*1000000000 from tz;
  tz:update gmtOffset:16h$gmtOffset*1000000000 from tz;
  tz:update localDateTime:gmtDateTime+gmtOffset from tz;
  tz:`gmtDateTime xasc tz;
  tz:update `g#timezoneID from tz;
  tz};

/ convert from local timestamp to gmt
.timezone.gmttolocal:{[tz;ts]
  if[not (tz:`$tz) in .timezone.zones;'`notValidTimezone];
  $[0>type ts;first;(::)]@exec gmtDateTime+gmtOffset from aj[`timezoneID`gmtDateTime;([]timezoneID:(),tz;gmtDateTime:ts,());.timezone.offsets]};

/ convert from gmt to local timestamp
.timezone.localtogmt:{[tz;ts]
  if[not (tz:`$tz) in .timezone.zones;'`notValidTimezone];
  $[0>type ts;first;(::)]@exec localDateTime-gmtOffset from aj[`timezoneID`localDateTime;([]timezoneID:(),tz;localDateTime:ts,());.timezone.offsets]};

/ convert between custom timestamps
.timezone.convert:{[stz;dtz;ts].timezone.gmttolocal[dtz;.timezone.localtogmt[stz;ts]]};

/ init function to read in timezone source data
.timezone.init:{
  .timezone.offsets:@[.timezone.config.read;`;{'`cantImportTimeZoneData}];
  .timezone.zones:exec distinct timezoneID from .timezone.offsets;
  };
