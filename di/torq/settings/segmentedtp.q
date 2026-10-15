/ track connections only
clientsopencloseonly:1b
zpsignore:(enlist`enabled)!enlist 0b
/ all required by init; override as -<key>. kdbtplog comes from the environment
stplgmultilog:`tabperiod
stplgmultilogperiod:0D01
stplgerrmode:1b
stplgbatchmode:`defaultbatch
stplgreplayperiod:`day
stplgcustomcsv:`
stplgerrorlogname:`segmentederrorlogfile
sctpchainedtp:0b
sctploggingmode:`none
sctptickerplantname:`stp1
sctptpconnsleep:10
sctptpcheckcycles:0W
sctpsubscribeto:`
sctpsubscribesyms:`
sctpreplay:0b
sctpschema:1b
createlogs:1b
