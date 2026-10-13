/ connections only; an app clients section replaces this whole section
clients:(enlist`opencloseonly)!enlist 1b
zpsignore:(enlist`enabled)!enlist 0b
/ every setting and its default; init requires them all. Each can be overridden from the command line
/ (-stplg_<key>, -sctp_<key>, -createlogs). kdbtplog comes from the environment
stplg_multilog:`tabperiod
stplg_multilogperiod:0D01
stplg_errmode:1b
stplg_batchmode:`defaultbatch
stplg_replayperiod:`day
stplg_customcsv:`
stplg_errorlogname:`segmentederrorlogfile
sctp_chainedtp:0b
sctp_loggingmode:`none
sctp_tickerplantname:`stp1
sctp_tpconnsleep:10
sctp_tpcheckcycles:0W
sctp_subscribeto:`
sctp_subscribesyms:`
sctp_replay:0b
sctp_schema:1b
createlogs:1b
