## KDB-X Package Testing Framework 

Includes a module that is used for testing another package

---

### To Use: 
Navigate to root project directory (kdbx-packages)

Run the KDB-X q session and then load the k4unit package. 
```bash
k4unit:use`k4unit

```

Then run the package test function to run the tests on another package, example:
```bash
k4unit.packagetest"timezone"

```

As part of the test cases it rquires the "before" test to module load the package with the same naming convention used for the tests, in this case "timezone":
```bash 
before,0,0,q,timezone:use`timezone,1,,Initialize package
true,0,0,q,2025.07.22D14:19:48.386221575=timezone.localtogmt[`$"America/New_York";2025.07.22D10:19:48.386221575],1,,Test local to gmt 1

---