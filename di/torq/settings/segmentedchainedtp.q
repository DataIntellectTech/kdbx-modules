/ chained segmented tickerplant settings
/ sctp logging is set by loggingmode, not createlogs
createlogs:0b
sctp.chainedtp:1b
sctp.loggingmode:`none
sctp.tickerplantname:`stp1
sctp.subscribeto:`
sctp.subscribesyms:`
sctp.replay:0b
sctp.schema:1b
connections:enlist`segmentedtp
/ connections only; an app clients section replaces this whole section
clients:(enlist`opencloseonly)!enlist 1b
zpsignore:(enlist`enabled)!enlist 0b
