## KDB+/Q Timezone Conversion Library

This project provides utilities to manage and convert timestamps across timezones in KDB+ using reference data from TimeZoneDB.

---

### TimeZoneDB Data Source

Timezone reference data is sourced from https://timezonedb.com/download and must be downloaded and provided to the package in order to function.
The downloadable .zip archive includes several files, but only time_zone.csv is used for core functionality.

There is a copy of tzinfo already in the package default subdirectory : timezone/config/tzinfo.
Should you need to update can follow the steps below.

Following transformations to save down and be formatted for the package: 
```q
t:flip `timezoneID`gmtDateTime`gmtOffset`dst!("S  JIB";csv)0:hsym `:time_zone.csv
`:tzinfo set t
`:tzinfo
```

---

### Package Initialization

Loading the module will automatically initialise using the included tzinfo.

```q
q)tz:use`timezone
```

If you wish to use an alternative tzinfo file, you can call the init function with
the path to your file

```q
q)tz:use`timezone
q)tz.init "path/to/tzinfo"
```

---

### Package Use

##### tz.localtogmt
Converts a local timestamp to GMT using timezoneID 
```q
// tz.localtogmt[localTimezone;timestamp]
q)tz.localtogmt[`$"America/New_York";2025.07.22D10:19:48.386221575]
2025.07.22D14:19:48.386221575
```

##### tz.gmttolocal
Converts a GMT timestamp to local using timezoneID
```q
// tz.gmttolocal[localTimezone;timestamp]
q)tz.gmttolocal[`$"America/New_York";2025.07.22D10:19:48.386221575]
2025.07.22D06:19:48.386221575
```

##### tz.convert
```q
// tz.convert[sourceTimezone;destTimezone;timestamp]
q)tz.convert[`$"America/New_York";`$"Europe/London";2025.07.22D10:19:48.386221575]
2025.07.22D15:19:48.386221575
```
