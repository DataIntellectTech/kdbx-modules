/ chained segmented tickerplant settings
/ sctp logging is set by loggingmode, not createlogs
createlogs:0b
sctp:`chainedtp`loggingmode`tickerplantname`subscribeto`subscribesyms`replay`schema!(1b;`none;`stp1;`;`;0b;1b)
connections:enlist`segmentedtp
/ connections only; an app clients section replaces this whole section
clients:(enlist`opencloseonly)!enlist 1b
zpsignore:(enlist`enabled)!enlist 0b
