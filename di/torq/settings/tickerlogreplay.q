/ tickerlogreplay settings
/ every basic-typed replay default as a flat key, so each can be overridden from the command line
/ (-replay_<key>); must agree with the module's own defaults
replay_firstmessage:0
replay_lastmessage:0W
replay_messagechunks:0W
replay_segmentedmode:1b
replay_autoreplay:1b
replay_schemafile:`
replay_tablelist:enlist`all
replay_hdbdir:`
replay_tplogfile:`
replay_tplogdir:`
replay_partitiontype:`date
replay_emptytables:1b
replay_sortafterreplay:1b
replay_basicmode:0b
replay_exitwhencomplete:1b
replay_checklogfiles:0b
replay_gc:1b
replay_clean:1b
replay_sortcsv:`
replay_partandmerge:0b
replay_tempdir:`:tempmergedir
replay_mergenumrows:10000000
replay_mergenumbytes:500000000
replay_mergemethod:`part
/ di.merge's mergebybytelimit and partlimit, passed to its init; must agree with di.merge's own defaults
merge_mergebybytelimit:0b
merge_partlimit:1000
