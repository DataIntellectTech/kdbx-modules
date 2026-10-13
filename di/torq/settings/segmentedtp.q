/ connections only; an app clients section replaces this whole section
clients:(enlist`opencloseonly)!enlist 1b
zpsignore:(enlist`enabled)!enlist 0b
/ every basic-typed stplg and sctp default, so each can be overridden from the command line
/ (-.stplg.<key>, -.sctp.<key>); must agree with the module's own defaults. kdbtplog comes from
/ the environment. An app stplg or sctp section replaces that whole section
stplg:`multilog`multilogperiod`errmode`batchmode`replayperiod`customcsv`errorlogname!(`tabperiod;0D01;1b;`defaultbatch;`day;`;`segmentederrorlogfile)
sctp:`chainedtp`loggingmode`tickerplantname`tpconnsleep`tpcheckcycles`subscribeto`subscribesyms`replay`schema!(0b;`none;`stp1;10;0W;`;`;0b;1b)
