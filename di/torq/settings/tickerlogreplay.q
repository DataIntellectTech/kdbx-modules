/ tickerlogreplay settings
/ all required by init; override basic-typed ones as -<key>
firstmessage:0
lastmessage:0W
messagechunks:0W
segmentedmode:1b
autoreplay:1b
schemafile:`
tablelist:enlist`all
hdbdir:`
tplogfile:`
tplogdir:`
partitiontype:`date
emptytables:1b
sortafterreplay:1b
basicmode:0b
exitwhencomplete:1b
checklogfiles:0b
gc:1b
clean:1b
sortcsv:`
partandmerge:0b
tempdir:`:tempmergedir
mergenumrows:10000000
mergenumbytes:500000000
mergemethod:`part
compression:()
mergenumtab:`quote`trade!10000 50000
/ passed to di.merge's init
mergebybytelimit:0b
partlimit:1000
