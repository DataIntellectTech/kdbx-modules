/ di.torq.proc.tickerlogreplay - replay tickerplant log files into an hdb

/ a symbol, a string or a list of strings (TOML has no symbol type)
tosym:{[x] $[type[x] in 0 10 -10h;`$x;x]};

/ log the error and exit
ex:{[id;message;code] .z.m.log[`error][id;message]; exit code}

/ exit if a variable is null
exitifnull:{[variable]
  if[null value variable;
    .z.m.log[`error][`init;"Variable ",(string variable)," is null but must be set"];
    exit 1]}

init:{[config;deps]
  if[not `log in key deps;'"di.torq.proc.tickerlogreplay: log dependency is required - see di.util.log"];
  .z.m.log:deps`log;
  .z.m.tplog:use`di.tplog;
  .z.m.dbw:use`di.dbwrite;
  .z.m.dbw.init enlist[`log]!enlist deps`log;
  {[c;ns] if[ns in key c;(` sv' (`$".",string ns),'key c ns) set' value c ns]}[config] each enlist`replay;
  @[`.replay;`schemafile`hdbdir`tplogdir`tplogfile`tablelist`partitiontype`sortcsv`tempdir`mergemethod;tosym];
  .replay.tablelist:(),.replay.tablelist;
  .z.m.merge:use`di.merge;
  .z.m.merge.init (enlist[`log]!enlist deps`log),$[`merge in key config;config`merge;()!()];
  / some variables must be set
  exitifnull each `.replay.schemafile`.replay.hdbdir, $[all null .replay`tplogdir`tplogfile; `.replay.tplogfile; ()];
  if[.replay.basicmode and (.replay.messagechunks within (0;-1 + 0W));
   ex[`replayinit; "if using basic mode, messagechunks must not be used (it should be set to 0W). basicmode will use .Q.hdpf to overwrite tables at the end of the replay";1]];
  if[not .replay.partitiontype in `date`month`year; ex[`replayinit;"partitiontype must be one of `date`month`year";1]];
  if[.replay.messagechunks=0;ex[`replayinit;"messagechunks value cannot be 0";2]];
  if[.replay.segmentedmode and ((0<>.replay.firstmessage) or 0W<>.replay.lastmessage);ex[`replayinit;"firstmessage must be 0 and lastmessage must be 0W while in segmented mode";1]];
  .replay.trackonly:.replay.messagechunks < 0;
  if[.replay.trackonly;.z.m.log[`info][`replayinit;"messagechunks value is negative - log replay progress will be tracked"]];
  .replay.messagechunks:abs .replay.messagechunks;
  if[.replay.partandmerge and .replay.hdbdir = .replay.tempdir;ex[`replayinit;"if using partandmerge replay, tempdir must be set to a different directory than the hdb";1]];
  if[.replay.partandmerge and .replay.sortafterreplay;(.replay.sortafterreplay:0b; .z.m.log[`info][`replayinit;"Setting sortafterreplay to 0b"])];
  / load the schema
  .z.m.log[`info][`replayinit;"loading schema file ",string .replay.schemafile];
  @[system;"l ",string .replay.schemafile;{ex[`replayinit;"failed to load replay file ",(string x)," - ",y;2]}[.replay.schemafile]];
  .z.m.log[`info][`replayinit;"hdb directory is set to ",string .replay.hdbdir:hsym .replay.hdbdir];
  .z.m.log[`info][`replayinit;"tempdir directory is set to ",string .replay.tempdir:hsym .replay.tempdir];
  / filter on the table list
  if[(not .replay.tablelist~enlist `all) and not .replay.segmentedmode; .replay.realupd:{[f;t;x] if[t in .replay.tablestoreplay; f[t;x]]}[.replay.realupd]];
  / chunked saves
  if[.replay.messagechunks < 0W; .replay.realupd:{[f;t;x] f[t;x]; .replay.checkcount[.replay.hdbdir;.replay.replaydate;1;.replay.tempdir]}[.replay.realupd]];
  / load the sort csv and kick off replay if auto-running
  $[null .replay.sortcsv;.z.m.dbw.setconfig sortdefault;.z.m.dbw.readcsv .replay.sortcsv];
  if[.replay.autoreplay;.replay.initandrun[]];
  };

/ save down manipulation and post replay hook, each defined if absent

/ table!function applied to a table before it is enumerated and saved
if[not `savedownmanipulation in key `.save;.save.savedownmanipulation:@[value;`.save.savedownmanipulation;()!()]];

/ manipulate a table at save down time
if[not `manipulate in key `.save;.save.manipulate:{[t;x]
 $[t in key .save.savedownmanipulation;
  @[.save.savedownmanipulation[t];x;{.z.m.log[`error][`manipulate;"save down manipulation failed : ",y];x}[x]];
  x]}];

/ called after a log's tables are saved, with the directory and partition
if[not `postreplay in key `.save;.save.postreplay:{[d;p]

	}];

/ settings
.replay.firstmessage:@[value;`.replay.firstmessage;0]                                   // the first message to execute
.replay.segmentedmode:@[value;`.replay.segmentedmode;1b]                                // segmented tickerplant logs
.replay.autoreplay:@[value;`.replay.autoreplay;1b]                                      // replay tplogs automatically
.replay.lastmessage:@[value;`.replay.lastmessage;0W]                                    // the last message to replay
.replay.messagechunks:@[value;`.replay.messagechunks;0W]                                // the number of messages to replay at once
.replay.schemafile:@[value;`.replay.schemafile;`]                                       // the schema file to load data in to
.replay.tablelist:@[value;`.replay.tablelist;enlist `all]                               // the tables to replay into. `all means all
.replay.hdbdir:@[value;`.replay.hdbdir;`]                                               // the hdb directory to write to
.replay.tplogfile:@[value;`.replay.tplogfile;`]                                         // the tp log file to replay; this or tplogdir
.replay.tplogdir:@[value;`.replay.tplogdir;`]                                           // the tp log directory to replay; this or tplogfile
.replay.partitiontype:@[value;`.replay.partitiontype;`date]                             // date, month or year
.replay.emptytables:@[value;`.replay.emptytables;1b]                                    // whether to overwrite any tables at start up
.replay.sortafterreplay:@[value;`.replay.sortafterreplay;1b]                            // re-sort and apply attributes at the end of the replay
.replay.basicmode:@[value;`.replay.basicmode;0b]                                        // replay everything, then save with .Q.hdpf
.replay.exitwhencomplete:@[value;`.replay.exitwhencomplete;1b]                          // exit when the replay is complete
.replay.checklogfiles:@[value;`.replay.checklogfiles;0b]                                // replay a "good" copy of a corrupt log
.replay.gc:@[value;`.replay.gc;1b]                                                      // garbage collect after each table save and each log
.replay.upd:@[value;`.replay.upd;{{[t;x] insert[t;x]}}]                                 // default upd function used for replaying data
.replay.clean:@[value;`.replay.clean;1b]                                                // clean existing folders on start up
.replay.sortcsv:@[value;`.replay.sortcsv;`]                                             // location of sort csv file; null is the default sort.csv
.replay.compression:@[value;`.replay.compression;()];                                   // the compress level, empty list if not required
.replay.partandmerge:@[value;`.replay.partandmerge;0b];                                 // partition to tempdir, then merge on disk
.replay.tempdir:hsym @[value;`.replay.tempdir;`:tempmergedir];                          // location to save data for partandmerge replay
.replay.mergenumrows:@[value;`.replay.mergenumrows;10000000];                           // default number of rows for merge process
.replay.mergenumtab:@[value;`.replay.mergenumtab;`quote`trade!10000 50000];             // number of rows per table for merge process
.replay.mergenumbytes:@[value;`.replay.mergenumbytes;500000000];                        // default number of bytes for merge process
.replay.mergemethod:@[value;`.replay.mergemethod;`part];                                // part, col or hybrid

/ save down settings
.save.savedownmanipulation:@[value;`.replay.savedownmanipulation;()!()]         // table!function applied to a table at save
.save.postreplay:@[value;`.replay.postreplay;{{[d;p] }}]                        // invoked after a log's tables are saved

// the path to the table to save
.replay.pathtotable:{[h;p;t] `$(string .Q.par[h;.replay.partitiontype$p;t]),"/"}

// create empty tables - we need to make sure we only create them once
.replay.emptytabs:`symbol$()
.replay.createemptytable:{[h;p;t;td]
 $[.replay.partandmerge;dest:td;dest:h];
 if[(not (path:.replay.pathtotable[dest;p;t]) in .replay.emptytabs) and .replay.emptytables;
  .z.m.log[`info][`replay;"creating empty table ",(string t)," at ",string path];
  .replay.emptytabs,:path;
  .replay.savetabdatatrapped[h;p;t;0#value t;0b;td]]}

.replay.savetabdata:{[h;p;t;data;UPSERT;td]
 $[.replay.partandmerge;path:.replay.pathtotable[td;p;t];path:.replay.pathtotable[h;p;t]];
 if[not .replay.partandmerge;.z.m.log[`info][`replay;"saving table ",(string t)," to ",string path]];
 .replay.pathlist[t],:path;
 $[.replay.partandmerge;.replay.savetablesbypart[td;p;t;h];$[UPSERT;upsert;set] . (path;.Q.en[h;0!.save.manipulate[t;data]])]
  }

.replay.savetabdatatrapped:{[h;p;t;data;UPSERT;td] .[.replay.savetabdata;(h;p;t;data;UPSERT;td);{.z.m.log[`error][`replay;"failed to save table : ",x]}]}

// this function should be invoked for saving tables
.replay.savetab:{[td;h;p;t]
 if[not .replay.partandmerge;.replay.createemptytable[h;p;t;td]];
 if[count value t;
  .z.m.log[`info][`replay;"saving ",(string t)," which has row count ",string count value t];
  .replay.savetabdatatrapped[h;p;t;value t;1b;td];
  delete from t;
  if[.replay.gc;.z.m.dbw.gc[]]]}

// apply the sorting and attributes at the end of the replay, from tablename!(list of paths)
.replay.applysortandattr:{[pathlist]
	{.z.m.dbw.sort . x} each flip (key;value) @\: distinct each pathlist
	};

// table names in count order, smallest first
.replay.tabsincountorder:{x iasc count each value each x}

// check if the count has been exceeded, and save down if it has
.replay.currentcount:0
.replay.totalcount:0
.replay.checkcount:{[h;p;counter;td]
 .replay.currentcount+:counter;
 if[.replay.currentcount >= .replay.messagechunks;
  $[.replay.trackonly;
    [.replay.totalcount +: .replay.currentcount;
     .z.m.log[`info][`replay;"replayed a chunk of ",(string .replay.messagechunks)," messages.  Total message count so far is ",string .replay.totalcount]];
    [.z.m.log[`info][`replay;"number of messages to replay at once (",(string .replay.messagechunks),") has been exceeded.  Saving down"];
     .replay.savetab[td;h;p] each .replay.tabsincountorder[.replay.tablestoreplay];
     .z.m.log[`info][`replay;"save complete- replaying next chunk of data"]]];
  .replay.currentcount:0]}

// function used to finish off the replay
.replay.finishreplay:{[h;p;td]
 // save down any tables which haven't been saved
 .replay.savetab[td;h;p] each .replay.tabsincountorder[.replay.tablestoreplay];
 // invoke any user defined post replay function
 .save.postreplay[h;p];
 }

// takes in log file directories made with segmented tickerplant
.replay.expandstplogs:{[logdirectories] // always a list
 {` sv'raze x,/:'key each x}$[`~.replay.tplogdir;{enlist first x};]hsym logdirectories
 };

.replay.replaylog:{[logfile]
 // set the upd function to be the initialupd function
 .replay.msgcount:.replay.currentcount:.replay.totalcount:0;
 // check if logfile is corrupt
 if[.replay.checklogfiles; logfile: .z.m.tplog.check[logfile;.replay.lastmessage]];
 $[.replay.firstmessage>0;
	[.z.m.log[`info][`replay;"skipping first ",(string .replay.firstmessage)," messages"];
         @[`.;`upd;:;.replay.initialupd]];
	@[`.;`upd;:;.replay.realupd]];
 .replay.tablecounts:.replay.errorcounts:()!();

 // If not running in segmented mode, reset replay date and clean HDB directory on each loop
 .replay.zipped:$[logfile like "*.gz";1b;0b];
 if[not .replay.segmentedmode;
   // Pull out date from TP log file name - *YYYY.MM.DD (+ .gz if zipped)
   .replay.replaydate:"D"$$[.replay.zipped;-3_-13#;-10#] string logfile;
   if[.replay.clean;.replay.cleanhdb .replay.replaydate]
  ];

 if[.replay.lastmessage<.replay.firstmessage; .z.m.log[`info][`replay;"lastmessage (",(string .replay.lastmessage),") is less than firstmessage (",(string .replay.firstmessage),"). Not replaying log file"]; :()];
 .z.m.log[`info][`replay;"replaying data from logfile ",(string logfile)," from message ",(string .replay.firstmessage)," to ",(string .replay.lastmessage),". Message indices are from 0 and inclusive - so both the first and last message will be replayed"];
 // when we do the replay, need to move the indexing, otherwise we won't replay the last message correctly
  .replay.replayinner[.replay.lastmessage+.replay.lastmessage<0W;logfile];

 .z.m.log[`info][`replay;"replayed data into tables with the following counts: ","; " sv {" = " sv string x}@'flip(key .replay.tablecounts;value .replay.tablecounts)];
 if[count .replay.errorcounts;
  .z.m.log[`error][`replay;"errors were hit when replaying the following tables: ","; " sv {" = " sv string x}@'flip(key .replay.errorcounts;value .replay.errorcounts)]];
 // set compression level
 if[3=count .replay.compression;
   .z.m.log[`info][`compression;"setting compression level to (",(";" sv string .replay.compression),")"];
   set[`.z.zd;.replay.compression];
   .z.m.log[`info][`compression;".z.zd has been set to (",(";" sv string .z.zd),")"]];

 $[.replay.basicmode;
  [.z.m.log[`info][`replay;"basicmode set to true, saving down tables with .Q.hdpf"];
   .Q.hdpf[`::;.replay.hdbdir;.replay.partitiontype$.replay.replaydate;`sym]];
  // if not in basic mode, then we need to finish off the replay
  .replay.finishreplay[.replay.hdbdir;.replay.replaydate;.replay.tempdir]];
  if[.replay.gc;.z.m.dbw.gc[]];
 }

// If replay date in HDB, delete tables/partition from the HDB so no data is duplicated
.replay.cleanhdb:{[dt]
  if[not (`$sd:string dt) in key .replay.hdbdir;.z.m.log[`info][`cleanhdb;"Date ",sd," not in HDB."];:()];
  delpaths:1_'string .Q.par[.replay.hdbdir;dt;] each $[`all~first .replay.tablelist;enlist `;.replay.tablestoreplay];
  {.z.m.log[`info][`cleanhdb;"Deleting ",x," from HDB."];system"rm -r ",x} each delpaths;
 };

// Replay log file, if file is zipped and the kdb+ version is at least 4.0 then replay through named pipe
.replay.replayinner:{[msgnum;logfile]
  if[not .replay.zipped;-11!(msgnum;logfile);:()];
  if[not .z.o like "l*";.z.m.log[`error][`replaylog;m:"Zipped log files can only be directly replayed on Linux systems"];'m];
  if[.z.K<4.0;.z.m.log[`error][`replaylog;m:"Zipped log files can only be directly replayed on kdb+ 4.0 or higher"];'m];

  .z.m.log[`info][`replay;"Replaying logfile ",(f:1_string logfile)," over named pipe"];
  -11!(msgnum;hsym `$fifo:.replay.readintofifo f);
  system "rm -f ",fifo;
  .replay.zipped:0b;
 };

// Create FIFO and unzip file into it, return FIFO name
.replay.readintofifo:{[filename]
  fifo:"/tmp/logfifo",string .z.i;
  fifostr:"mkfifo ",fifo,";gunzip -cd ",filename," > ",fifo," &";
  @[system;fifostr;{.z.m.log[`error][`replay;"Failed to read log into named pipe"]}];
  fifo
 };

// upd functions down here
.replay.realupd:{[f;t;x]
	// increment the tablecounts
        .replay.tablecounts[t]+:count first x;
	// run the supplied function in the error trap
	.[f;(t;x);{[t;x;e] .replay.errorcounts[t]+:count first x}[t;x]];
	}[.replay.upd]

.replay.initialupd:{[t;x]
	 // spin through the first X messages
	 $[.replay.msgcount < (.replay.firstmessage - 1);
	.replay.msgcount+:1;
	// Once we reach the correct message, reset the upd function
	@[`.;`upd;:;.replay.realupd]]
	}

// extract user defined row counts
.replay.mergemaxrows:{[tabname] .replay.mergenumrows^.replay.mergenumtab[tabname]};

// post replay function for merge replay, invoked after all the tables have been written down for a given log file
.replay.postreplaymerge:{[td;p;h]
 system"mkdir -p ",1_string .Q.par[td;p;`]; // ensures directory exists before removed
 mergelimits:(.replay.tabsincountorder[.replay.tablestoreplay],())!$[.z.m.merge.getmergebybytelimit[];(count .replay.tabsincountorder[.replay.tablestoreplay])#.replay.mergenumbytes;({[x] .replay.mergenumrows^.replay.mergemaxrows[x]}.replay.tabsincountorder[.replay.tablestoreplay])],();
 // merge the tables from each partition in the tempdir together
 .replay.merge[td;p;;mergelimits;h] each .replay.tabsincountorder[.replay.tablestoreplay];
 system"rm -r ",1_string .Q.par[td;p;`]; // delete the contents of tempdir after merge completion
 }

// function to upsert to specified directory
.replay.upserttopartition:{[h;dir;tablename;tabdata;pt;expttype;expt]
 dirpar:.Q.par[dir;pt;`$string first expt];
 directory:` sv dirpar,tablename,`;
 // make directories for tables if they don't exist
 if[count tabpar:.replay.tabsincountorder[.replay.tablestoreplay] except key dirpar;
  .z.m.log[`info][`dir;"creating directories under ",1_string dirpar];
  tabpar:tabpar except `heartbeat`logmsg;
  .[{[d;h;t](` sv d,t,`) set .Q.en[h;0#value t]};] each dirpar,'h,'tabpar];
  .z.m.log[`info][`save;"saving ",(string tablename)," data to partition ",string directory];
  .[
  upsert;
  (directory;r:update `sym!sym from ?[tabdata;{(x;y;(),z)}[in;;]'[expttype;expt];0b;()]);
  {[e] .z.m.log[`error][`savetablesbypart;"Failed to save table to disk : ",e];'e}];
  /-key in partsizes are directory to partition, need to drop training slash in directory key
  .z.m.merge.trackpartition[first ` vs directory;count r;-22!r];
  };

.replay.savetablesbypart:{[dir;pt;tablename;h]
 arows: count value tablename;
 .z.m.log[`info][`rowcheck;"the ",(string tablename)," table consists of ", (string arows), " rows"];
 // get additional partition(s) defined by parted attribute in sort.csv
 extrapartitiontype:.z.m.merge.getextrapartitiontype[.z.m.dbw.getconfig[];tablename];

 // check each partition type actually is a column in the selected table
 .z.m.merge.checkpartitiontype[tablename;extrapartitiontype];
 // enumerate data to be upserted
 enumdata:update (`. `sym)?sym from .Q.en[h;value tablename];
 // get list of distinct combiniations for partition directories
 extrapartitions:(`. `sym)?.z.m.merge.getextrapartitions[tablename;extrapartitiontype];

 .z.m.log[`info][`save;"enumerated ",(string tablename)," table"];
 // upsert data to specific partition directory
 .replay.upserttopartition[h;dir;tablename;enumdata;pt;extrapartitiontype] each extrapartitions;
 // empty the table
 .z.m.log[`info][`delete;"deleting ",(string tablename)," data from in-memory table"];
 @[`.;tablename;0#];
 // run a garbage collection (if enabled)
 if[.replay.gc;.z.m.dbw.gc[]];
 };


.replay.merge:{[dir;pt;tablename;mergelimits;h]
 // get int partitions
 intpars:asc key ` sv dir,`$string pt; // list of enumerated partitions 0 1 2 3...
 k:key each intdir:.Q.par[hsym dir;pt] each intpars; // list of table names
 if[0=count raze k inter\: tablename; :()];
 // get list of partition directories containing specified table
 partdirs:` sv' (intdir,'parts) where not ()~/:parts:k inter\: tablename; // get each of the directories that hold the table
 // permanent storage destination, where data being merged too
 dest:.Q.par[h;pt;tablename];
 // exit function if no subdirectories are found
 if[0=count partdirs; :()];
 // if no table data set empty table. If data to merge, merge with correct merge function
 $[0 = count partdirs inter exec ptdir from .z.m.merge.getpartsizes[];
   [.z.m.log[`warn][`merge;"no records for ", string[tablename]];
    (` sv dest,`) set @[.Q.en[h;value tablename];.z.m.merge.getextrapartitiontype[.z.m.dbw.getconfig[];tablename];`p#];
   ];
   [$[.replay.mergemethod~`part;
      [dest:` sv .Q.par[h;pt;tablename],`; // provides path to where to move data to
       /-get chunks to partitions to merge in batch
       partchunks:.z.m.merge.getpartchunks[partdirs;mergelimits[tablename]];
       .z.m.merge.mergebypart[.z.m.merge.getextrapartitiontype[.z.m.dbw.getconfig[];tablename];dest]'[partchunks];
      ];
      .replay.mergemethod~`col;
       [.z.m.merge.mergebycol[(tablename;value tablename);dest]'[partdirs];
       /- merging data by column does not create .d file - set it here after merge
       .z.m.log[`info][`merge;"setting .d file"];
       (` sv dest,`.d) set cols value tablename;
       ];
       .z.m.merge.mergehybrid[.z.m.merge.getextrapartitiontype[.z.m.dbw.getconfig[];tablename];(tablename;value tablename);dest;partdirs;mergelimits[tablename]]
       ]
     ]
   ];
 .z.m.log[`info][`merge;"deleting ", string[tablename], " from temp storage"];
 {system"rm -r ",1_string x} each partdirs;
 // set the attributes
 .z.m.log[`info][`merge;"setting attributes"];
 @[dest;;`p#] each .z.m.merge.getextrapartitiontype[.z.m.dbw.getconfig[];tablename];
 .z.m.log[`info][`merge;"merge complete"];
 // run a garbage collection (if enabled)
 if[.replay.gc;.z.m.dbw.gc[]];
 };

// Return log file if it exists and not in segmented mode
.replay.getlogfile:{
  if[.replay.segmentedmode;.z.m.log[`error][`getlogfile;m:"Segmented mode requires tplogdir."];'m];
  if[()~key hsym f:.replay.tplogfile;.z.m.log[`error][`getlogfile;m:"Specified tplogfile ",string[f]," does not exist"];'m];
  enlist hsym f
 };

// Return contents of log directory if it exists
.replay.getlogdir:{
  if[()~key hsym d:.replay.tplogdir;.z.m.log[`error][`getlogdir;m:"Specified log directory ",string[d]," does not exist"];'m];
  if[d like "*.gz";.z.m.log[`error][`getlogdir;m:"Zipped log directories not supported."];'m];
  $[.replay.segmentedmode;.replay.getstplogs[d];.Q.dd[logdir;] each key logdir:hsym d]
 };

// Use STP meta table and tplogdir to build log names
.replay.getstplogs:{[logdir]
  // If trying to replay zipped files on Windows, error out
  winzip:(.z.o like "w*") and z:`stpmeta.gz in key d:hsym logdir;
  if[winzip;.z.m.log[`error][`replaylog;m:"Zipped log files cannot be directly replayed on Windows"];'m];

  // If meta table is zipped, assume all other logs are zipped as well and build log names accordingly
  if[z;system "gunzip ",1_string .Q.dd[d;`stpmeta.gz]];
  metatable:@[get;.Q.dd[d;`stpmeta];{.z.m.log[`error][`getstpmeta;m:"Log directory must contain valid STP meta table"];'m}];
  if[z;system "gzip ",1_string .Q.dd[d;`stpmeta]];
  names:exec distinct logname from metatable where any each tbls in .replay.tablestoreplay;
  .Q.dd[d;] each $[z;.Q.dd[;`gz];::] each last each ` vs' names
 };

// Set up log replay list and clean HDB if necessary, kick off replay
.replay.initandrun:{
  if[all not null .replay[`tplogfile`tplogdir];.z.m.log[`error][`getlogs;m:"Can't pass in log file and directory."];'m];

  .z.m.log[`info][`initandrun;"Initialising replay settings."];
  .replay.tablestoreplay:$[`all~first .replay.tablelist;tables[];.replay.tablelist,()];
  .replay.logstoreplay:$[not null .replay.tplogfile;.replay.getlogfile[];.replay.getlogdir[]];
  if[not count r:.replay.logstoreplay;.z.m.log[`error][`initandrun;m:"No log files found"];'m];

  // If in segmented mode, get replay date and clean HDB once
  if[.replay.segmentedmode;
    // Pull out the date from the STP log file name - *_YYYYMMDDhhmmss (+ .gz if zipped)
    .replay.replaydate:first l:"D"$$[first[r] like "*.gz";-9_-17#;-6_-14#] each string r;
    if[not 1=count distinct l;.z.m.log[`error][`replay;m:"Cannot replay logs from different dates in segmented mode!"];'m];
    if[.replay.clean;.replay.cleanhdb .replay.replaydate]
   ];


  // Replay all logs and exit
  .z.m.log[`info][`initandrun;"Replaying the following log(s): ",csv sv 1_'string .replay.logstoreplay];
  .replay.pathlist:()!();
  .replay.replaylog each .replay.logstoreplay;
  if[.replay.sortafterreplay;.replay.applysortandattr[.replay.pathlist]];
  if[.replay.partandmerge;.replay.postreplaymerge[.replay.tempdir;.replay.replaydate;.replay.hdbdir]];
  .z.m.log[`info][`replay;"replay complete"];
  if[.replay.exitwhencomplete;exit 0];
 };
