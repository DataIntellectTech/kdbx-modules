// Library for converting between and managing timezones

// Override variables to change internal logic
.timezone.config.file:""; / - filepath of timezone data to be downloaded with utility script

// Function reponsible for reading in files and formatting timezone table for function reference - takes from csvs 
.timezone.config.read:{
    tz:flip `timezoneID`gmtDateTime`gmtOffset`dst!("S  JIB";csv)0:hsym `$.timezone.config.file;
    tz:delete from tz where gmtDateTime>=10170056837;
    tz:update gmtDateTime:12h$-946684800000000000+gmtDateTime*1000000000 from tz;
    tz:update gmtOffset:16h$gmtOffset*1000000000 from tz;
    tz:update localDateTime:gmtDateTime+gmtOffset from tz;
    tz:`gmtDateTime xasc tz;
    tz:update `g#timezoneID from tz;
    tz};

// Convert from local timestamp to gmt
.timezone.gmttolocal:{[tz;ts]
    if[not (tz:`$tz) in .timezone.zones;'`notValidTimezone];
    $[0>type ts;first;(::)]@exec gmtDateTime+gmtOffset from aj[`timezoneID`gmtDateTime;([]timezoneID:(),tz;gmtDateTime:ts,());.timezone.offsets]};     

// Convert from gmt to local timestamp
.timezone.localtogmt:{[tz;ts]
    if[not (tz:`$tz) in .timezone.zones;'`notValidTimezone];
    $[0>type ts;first;(::)]@exec localDateTime-gmtOffset from aj[`timezoneID`localDateTime;([]timezoneID:(),tz;localDateTime:ts,());.timezone.offsets]};

// Convert between custom timestamps
.timezone.convert:{[stz;dtz;ts].timezone.gmttolocal[dtz;.timezone.localtogmt[stz;ts]]};

// Init function to read in timezone source data
.timezone.init:{
    .timezone.offsets:@[.timezone.config.read;`;{'`cantImportTimeZoneData}];
    .timezone.zones:exec distinct timezoneID from .timezone.offsets;
    };
