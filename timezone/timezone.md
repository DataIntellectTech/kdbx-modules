## KDB+/Q Timezone Conversion Library

This project provides utilities to manage and convert timestamps across timezones in KDB+ using reference data from TimeZoneDB.

---

### TimeZoneDB Data Source

Timezone reference data is sourced from https://timezonedb.com/download and must be downloaded and provided to the package in order to function.
The downloadable .zip archive includes several files, but only time_zone.csv is used for core functionality.

Following transformations to save down and be formatted for the package: 
```q
t:flip `timezoneID`gmtDateTime`gmtOffset`dst!("S  JIB";csv)0:hsym `:time_zone.csv
`:tzinfo set t
`:tzinfo
```

---

### Package Initialization

Set the path to your timezone data file

```q
/ Overwrite tzinfo file path if neccessary
.timezone.config.file:"/your/output/directory/tzinfo"
/ Initalize package
.timezone.init[]
```

---

### Package Use

##### .timezone.localtogmt
Converts a local timestamp to GMT using timezoneID 
```q
// .timezone.localtogmt[localTimezone;timestamp]
.timezone.localtogmt["America/New_York";2025.07.22D10:19:48.386221575]
2025.07.22D14:19:48.386221575
```

##### .timezone.gmttolocal
Converts a GMT timestamp to local using timezoneID
```q
// .timezone.gmttolocal[localTimezone;timestamp]
.timezone.gmttolocal["America/New_York";2025.07.22D10:19:48.386221575]
2025.07.22D06:19:48.386221575
```

##### .timezone.convert
```q
// .timezone.convert[sourceTimezone;destTimezone;timestamp]
.timezone.convert["America/New_York";"Europe/London";2025.07.22D10:19:48.386221575]
2025.07.22D15:19:48.386221575
```
