/ connections only; an app clients section replaces this whole section
clients:(enlist`opencloseonly)!enlist 1b
zpsignore:(enlist`enabled)!enlist 0b
/ every basic-typed stplg and sctp default as a flat key, so each can be overridden from the command line
/ (-stplg.<key>, -sctp.<key>); must agree with the module's own defaults. kdbtplog comes from the environment
stplg.multilog:`tabperiod
stplg.multilogperiod:0D01
stplg.errmode:1b
stplg.batchmode:`defaultbatch
stplg.replayperiod:`day
stplg.customcsv:`
stplg.errorlogname:`segmentederrorlogfile
sctp.chainedtp:0b
sctp.loggingmode:`none
sctp.tickerplantname:`stp1
sctp.tpconnsleep:10
sctp.tpcheckcycles:0W
sctp.subscribeto:`
sctp.subscribesyms:`
sctp.replay:0b
sctp.schema:1b
