## KDB-X Package Testing Framework 

Includes a simple script to run unit tests using our package framework

---

### To Use: 
Navigate to root project directory (kdbx-packages)

Run packagetest.q script specfiying package that you want to test
```bash
q test/packagetest.q -package timezone
```

Process will display all test results with fails first. Querying in memory table: KUTR you can investigate any futher.

---