/ tickerlogreplay settings
/ every basic-typed replay default as a flat key, so each can be overridden from the command line
/ (-replay.<key>); must agree with the module's own defaults
replay.firstmessage:0
replay.lastmessage:0W
replay.messagechunks:0W
replay.segmentedmode:1b
replay.autoreplay:1b
replay.schemafile:`
replay.tablelist:enlist`all
replay.hdbdir:`
replay.tplogfile:`
replay.tplogdir:`
replay.partitiontype:`date
replay.emptytables:1b
replay.sortafterreplay:1b
replay.basicmode:0b
replay.exitwhencomplete:1b
replay.checklogfiles:0b
replay.gc:1b
replay.clean:1b
replay.sortcsv:`
replay.partandmerge:0b
replay.tempdir:`:tempmergedir
replay.mergenumrows:10000000
replay.mergenumbytes:500000000
replay.mergemethod:`part
/ di.merge's mergebybytelimit and partlimit, passed to its init; must agree with di.merge's own defaults
merge.mergebybytelimit:0b
merge.partlimit:1000
