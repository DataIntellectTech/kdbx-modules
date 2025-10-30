## KDB-X module Testing Framework 

Includes a module that is used for testing another module

---

### To Use: 
Navigate to root project directory (kdbx-modules)

Run the KDB-X q session and then load the k4unit module. 
```q
q)k4unit:use`di.k4unit
```

Then run the module test function to run the tests on another module, example:
```q
q)k4unit.moduletest`di.timezone
```

As part of the test cases it rquires the "before" test to module load the module with the same naming convention used for the tests, in this case "timezone":
``` 
before,0,0,q,timezone:use`di.timezone,1,,Initialize module
true,0,0,q,2025.07.22D14:19:48.386221575=timezone.localtogmt[`$"America/New_York";2025.07.22D10:19:48.386221575],1,,Test local to gmt 1
```

---

### Saving & loading results

Results can be saved & loaded from CSV (default delimiter `,` can be changed, see
Configuration section) using following functions:

```q
/ save currently stored results
q)k4unit.saveresults`:path/to/output.csv
```

```q
/ load previously stored results
q)k4unit.loadresults`:path/to/output.csv
action ms bytes lang code                                                                                                                                                          ..
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------..
true   0  0     q    2025.07.22D14:19:48.386221575=timezone.localtogmt[`$"America/New_York";2025.07.22D10:19:48.386221575]                                                         ..
true   0  0     q    1999.03.03D12:13:48.919241092=timezone.localtogmt[`$"Europe/London";1999.03.03D12:13:48.919241092]                                                            ..
true   0  0     q    1967.05.02D21:03:52.857237462=timezone.gmttolocal[`$"America/Toronto";1967.05.03D01:03:52.857237462]                                                          ..
true   0  0     q    2017.09.01D04:03:52.857237462=timezone.gmttolocal[`$"America/Los_Angeles";2017.09.01D11:03:52.857237462]                                                      ..
true   0  0     q    2025.07.21D19:19:48.386221575=timezone.convert[`$"Asia/Singapore";`$"America/Vancouver";2025.07.22D10:19:48.386221575]                                        ..
true   0  0     q    2025.07.24D15:27:58.224707599=timezone.convert[`$"America/New_York";`$"America/Toronto";2025.07.24D15:27:58.224707599]                                        ..
true   0  0     q    2025.11.02D01:30:00.000=timezone.convert[`$"America/New_York";`$"America/New_York";2025.11.02D01:30:00.000]                                                   ..
true   0  0     q    (2025.08.03D22:50:46.515073740;2025.08.04D22:50:46.515073740;2025.08.05D22:50:46.515073740)~timezone.localtogmt[`$"America/Toronto";(2025.08.03D18:50:46.51507..
true   0  0     q    (2025.08.03D11:50:46.515073740;2025.08.04D11:50:46.515073740;2025.08.05D11:50:46.515073740)~timezone.gmttolocal[`$"America/Vancouver";(2025.08.03D18:50:46.515..
true   0  0     q    (2025.08.05D19:50:46.515073740;2025.08.05D14:50:46.515073740)~timezone.gmttolocal[`$("Europe/London";"America/New_York");2# 2025.08.05D18:50:46.515073740]    ..
true   0  0     q    (2025.08.05D17:50:46.515073740;2025.08.05D22:50:46.515073740)~timezone.localtogmt[`$("Europe/London";"America/New_York");2# 2025.08.05D18:50:46.515073740]    ..
true   0  0     q    `notValidTimezone~.[timezone.gmttolocal;(`testTimezone;.z.p);{`$x}]                                                                                           ..
true   0  0     q    `notValidTimezone~.[timezone.localtogmt;(`testTimezone;.z.p);{`$x}]           
```

### Configuration

There are 3 functions provided for configuring k4unit.

```q
/ set debug on/off, can be 0b or 1b. Default = 0b
q)k4unit.debug 1b
```

```q
/ set verbose mode, can be 0 (no logging to console), 1 (log filenames) or 2 (log tests). Default = 1
q)k4unit.verbose 0
```

```q
/ set delimiter for saving/loading results and test CSVs, must be passed as a char. Default = ,
q)k4unit.delim "|"
```
