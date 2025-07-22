## KDB+/Q Timezone Conversion Library

This project provides utilities to manage and convert timestamps across timezones in KDB+ using reference data from TimeZoneDB.

---

### TimeZoneDB Data Source

Timezone reference data is sourced from https://timezonedb.com/download and must be downloaded and provided to the package in order to function.
The downloadable .zip archive includes several files, but only time_zone.csv is used for core functionality.
You can update this data manually or use the provided Python script to automate the process.

---

### Python Utility for Data Updates

A Python script (timezone_download.py) is available to automate daily downloads and updates of time_zone.csv:
Steps performed:
- Downloads ZIP archive from TimeZoneDB.
- Extracts contents into a specified directory.
- Cleans out unused files (e.g. README, country.csv, database.sql).
- Prepares time_zone.csv for use in package.
Command-line usage:
```sh
python downloader.py \
  --fileurl https://timezonedb.com/files/TimeZoneDB.csv.zip \
  --output /your/output/directory
```

Can optionally specficy both fileurl and output directory. If not provided download will default to url in args and the directory where the timezone_download.py script is located. This can be scheduled daily via cron or other job schedulers to update intermittently, updating once daily should be more then sufficient.

### Manual Data Updates

If you prefer not to use the script:
- Go to https://timezonedb.com/download
- Download the TimeZoneDB.csv.zip file
- Extract it manually
- Place time_zone.csv in your desired config directory
- Ensure your .timezone.config.file variable is set prior to package initilization

---

### Package Initialization

Set the path to your timezone data file

```q
// Point to timezone data file
.timezone.config.file:"/your/output/directory/time_zone.csv"
// Initalize package
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
