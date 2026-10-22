/ di.torq.proc.tickerlogreplay - replay tickerplant log files into an hdb

/ a symbol, a string or a list of strings (TOML has no symbol type)
tosym:{[x] $[type[x] in 0 10 -10h;`$x;x]};

/ log the error and exit
ex:{[id;message;code] .z.m.log[`error][id;message]; exit code}

/ exit if a setting is null
exitifnull:{[name;val]
  if[null val;
    .z.m.log[`error][`init;"Variable ",(string name)," is null but must be set"];
    exit 1]}

init:{[config;deps]
  if[not `log in key deps;'"di.torq.proc.tickerlogreplay: log dependency is required - see di.util.log"];
  .z.m.log:deps`log;
  .z.m.tplog:use`di.tplog;
  .z.m.dbw:use`di.dbwrite;
  / the save down hooks from config go to di.dbwrite
  sdm:$[`savedownmanipulation in key config;config`savedownmanipulation;()!()];
  pr:$[`postreplay in key config;config`postreplay;{[d;p]}];
  .z.m.dbw.init `log`savedownmanipulation`postreplay!(deps`log;sdm;pr);
  .z.m.os:use`di.os;
  / all settings required
  req:`firstmessage`lastmessage`messagechunks`segmentedmode`autoreplay`schemafile`tablelist`hdbdir`tplogfile`tplogdir;
  req,:`partitiontype`emptytables`sortafterreplay`basicmode`exitwhencomplete`checklogfiles`gc`clean`sortcsv`compression;
  req,:`partandmerge`tempdir`mergenumrows`mergenumtab`mergenumbytes`mergemethod`mergebybytelimit`partlimit;
  if[count m:req except key config;
    '"di.torq.proc.tickerlogreplay: missing settings: ",", " sv string m];
  .z.m.firstmessage:config`firstmessage;
  .z.m.lastmessage:config`lastmessage;
  .z.m.messagechunks:config`messagechunks;
  .z.m.segmentedmode:config`segmentedmode;
  .z.m.autoreplay:config`autoreplay;
  .z.m.schemafile:tosym config`schemafile;
  .z.m.tablelist:tosym config`tablelist;
  .z.m.hdbdir:tosym config`hdbdir;
  .z.m.tplogfile:tosym config`tplogfile;
  .z.m.tplogdir:tosym config`tplogdir;
  .z.m.partitiontype:tosym config`partitiontype;
  .z.m.emptytables:config`emptytables;
  .z.m.sortafterreplay:config`sortafterreplay;
  .z.m.basicmode:config`basicmode;
  .z.m.exitwhencomplete:config`exitwhencomplete;
  .z.m.checklogfiles:config`checklogfiles;
  .z.m.gc:config`gc;
  .z.m.clean:config`clean;
  .z.m.sortcsv:tosym config`sortcsv;
  .z.m.compression:config`compression;
  .z.m.partandmerge:config`partandmerge;
  .z.m.tempdir:tosym config`tempdir;
  .z.m.mergenumrows:config`mergenumrows;
  .z.m.mergenumtab:config`mergenumtab;
  .z.m.mergenumbytes:config`mergenumbytes;
  .z.m.mergemethod:tosym config`mergemethod;
  .z.m.tablelist:(),tablelist;
  .z.m.merge:use`di.merge;
  .z.m.merge.init `log`mergebybytelimit`partlimit!(deps`log;config`mergebybytelimit;config`partlimit);
  / some variables must be set
  exitifnull[`schemafile;schemafile];
  exitifnull[`hdbdir;hdbdir];
  if[all null (tplogdir;tplogfile);exitifnull[`tplogfile;tplogfile]];
  if[basicmode and (messagechunks within (0;-1 + 0W));
   ex[`replayinit; "if using basic mode, messagechunks must not be used (it should be set to 0W). basicmode will use .Q.hdpf to overwrite tables at the end of the replay";1]];
  if[not partitiontype in `date`month`year; ex[`replayinit;"partitiontype must be one of `date`month`year";1]];
  if[messagechunks=0;ex[`replayinit;"messagechunks value cannot be 0";2]];
  if[segmentedmode and ((0<>firstmessage) or 0W<>lastmessage);ex[`replayinit;"firstmessage must be 0 and lastmessage must be 0W while in segmented mode";1]];
  .z.m.trackonly:messagechunks < 0;
  if[trackonly;.z.m.log[`info][`replayinit;"messagechunks value is negative - log replay progress will be tracked"]];
  .z.m.messagechunks:abs messagechunks;
  if[partandmerge and hdbdir = tempdir;ex[`replayinit;"if using partandmerge replay, tempdir must be set to a different directory than the hdb";1]];
  if[partandmerge and sortafterreplay;(.z.m.sortafterreplay:0b; .z.m.log[`info][`replayinit;"Setting sortafterreplay to 0b"])];
  / load the schema
  .z.m.log[`info][`replayinit;"loading schema file ",string schemafile];
  @[system;"l ",string schemafile;{ex[`replayinit;"failed to load replay file ",(string x)," - ",y;2]}[schemafile]];
  .z.m.log[`info][`replayinit;"hdb directory is set to ",string .z.m.hdbdir:hsym hdbdir];
  .z.m.log[`info][`replayinit;"tempdir directory is set to ",string .z.m.tempdir:hsym tempdir];
  / the replay upd from config, default insert
  .z.m.realupd:applyupd $[`upd in key config;config`upd;{[t;x] insert[t;x]}];
  / filter on the table list
  if[(not tablelist~enlist `all) and not segmentedmode; .z.m.realupd:{[f;t;x] if[t in tablestoreplay; f[t;x]]}[realupd]];
  / chunked saves
  if[messagechunks < 0W; .z.m.realupd:{[f;t;x] f[t;x]; checkcount[hdbdir;replaydate;1;tempdir]}[realupd]];
  / load the sort csv and kick off replay if auto-running
  $[null sortcsv;.z.m.dbw.setconfig sortdefault;.z.m.dbw.readcsv sortcsv];
  if[autoreplay;initandrun[]];
  };

// the path to the table to save
pathtotable:{[h;p;t] `$(string .Q.par[h;partitiontype$p;t]),"/"}

// create empty tables - we need to make sure we only create them once
emptytabs:`symbol$()
createemptytable:{[h;p;t;td]
 $[partandmerge;dest:td;dest:h];
 if[(not (path:pathtotable[dest;p;t]) in emptytabs) and emptytables;
  .z.m.log[`info][`replay;"creating empty table ",(string t)," at ",string path];
  .z.m.emptytabs,:path;
  savetabdatatrapped[h;p;t;0#value t;0b;td]]}

savetabdata:{[h;p;t;data;UPSERT;td]
 $[partandmerge;path:pathtotable[td;p;t];path:pathtotable[h;p;t]];
 if[not partandmerge;.z.m.log[`info][`replay;"saving table ",(string t)," to ",string path]];
 .z.m.pathlist[t],:path;
 $[partandmerge;savetablesbypart[td;p;t;h];$[UPSERT;upsert;set] . (path;.Q.en[h;0!.z.m.dbw.manipulate[t;data]])]
  }

savetabdatatrapped:{[h;p;t;data;UPSERT;td] .[savetabdata;(h;p;t;data;UPSERT;td);{.z.m.log[`error][`replay;"failed to save table : ",x]}]}

// this function should be invoked for saving tables
savetab:{[td;h;p;t]
 if[not partandmerge;createemptytable[h;p;t;td]];
 if[count value t;
  .z.m.log[`info][`replay;"saving ",(string t)," which has row count ",string count value t];
  savetabdatatrapped[h;p;t;value t;1b;td];
  delete from t;
  if[gc;.z.m.dbw.gc[]]]}

// apply the sorting and attributes at the end of the replay, from tablename!(list of paths)
applysortandattr:{[pathlist]
	{.z.m.dbw.sort . x} each flip (key;value) @\: distinct each pathlist
	};

// table names in count order, smallest first
tabsincountorder:{x iasc count each value each x}

// check if the count has been exceeded, and save down if it has
currentcount:0
totalcount:0
checkcount:{[h;p;counter;td]
 .z.m.currentcount+:counter;
 if[currentcount >= messagechunks;
  $[trackonly;
    [.z.m.totalcount +: currentcount;
     .z.m.log[`info][`replay;"replayed a chunk of ",(string messagechunks)," messages.  Total message count so far is ",string totalcount]];
    [.z.m.log[`info][`replay;"number of messages to replay at once (",(string messagechunks),") has been exceeded.  Saving down"];
     savetab[td;h;p] each tabsincountorder[tablestoreplay];
     .z.m.log[`info][`replay;"save complete- replaying next chunk of data"]]];
  .z.m.currentcount:0]}

// function used to finish off the replay
finishreplay:{[h;p;td]
 // save down any tables which haven't been saved
 savetab[td;h;p] each tabsincountorder[tablestoreplay];
 // invoke any user defined post replay function
 .z.m.dbw.postreplay[h;p];
 }

// takes in log file directories made with segmented tickerplant
expandstplogs:{[logdirectories] // always a list
 {` sv'raze x,/:'key each x}$[`~tplogdir;{enlist first x};]hsym logdirectories
 };

replaylog:{[logfile]
 // set the upd function to be the initialupd function
 .z.m.msgcount:.z.m.currentcount:.z.m.totalcount:0;
 // check if logfile is corrupt
 if[checklogfiles; logfile: .z.m.tplog.check[logfile;lastmessage]];
 $[firstmessage>0;
	[.z.m.log[`info][`replay;"skipping first ",(string firstmessage)," messages"];
         @[`.;`upd;:;initialupd]];
	@[`.;`upd;:;realupd]];
 .z.m.tablecounts:.z.m.errorcounts:()!();

 // If not running in segmented mode, reset replay date and clean HDB directory on each loop
 .z.m.zipped:$[logfile like "*.gz";1b;0b];
 if[not segmentedmode;
   // Pull out date from TP log file name - *YYYY.MM.DD (+ .gz if zipped)
   .z.m.replaydate:"D"$$[zipped;-3_-13#;-10#] string logfile;
   if[clean;cleanhdb replaydate]
  ];

 if[lastmessage<firstmessage; .z.m.log[`info][`replay;"lastmessage (",(string lastmessage),") is less than firstmessage (",(string firstmessage),"). Not replaying log file"]; :()];
 .z.m.log[`info][`replay;"replaying data from logfile ",(string logfile)," from message ",(string firstmessage)," to ",(string lastmessage),". Message indices are from 0 and inclusive - so both the first and last message will be replayed"];
 // when we do the replay, need to move the indexing, otherwise we won't replay the last message correctly
  replayinner[lastmessage+lastmessage<0W;logfile];

 .z.m.log[`info][`replay;"replayed data into tables with the following counts: ","; " sv {" = " sv string x}@'flip(key tablecounts;value tablecounts)];
 if[count errorcounts;
  .z.m.log[`error][`replay;"errors were hit when replaying the following tables: ","; " sv {" = " sv string x}@'flip(key errorcounts;value errorcounts)]];
 // set compression level
 if[3=count compression;
   .z.m.log[`info][`compression;"setting compression level to (",(";" sv string compression),")"];
   set[`.z.zd;compression];
   .z.m.log[`info][`compression;".z.zd has been set to (",(";" sv string .z.zd),")"]];

 $[basicmode;
  [.z.m.log[`info][`replay;"basicmode set to true, saving down tables with .Q.hdpf"];
   .Q.hdpf[`::;hdbdir;partitiontype$replaydate;`sym]];
  // if not in basic mode, then we need to finish off the replay
  finishreplay[hdbdir;replaydate;tempdir]];
  if[gc;.z.m.dbw.gc[]];
 }

// If replay date in HDB, delete tables/partition from the HDB so no data is duplicated
cleanhdb:{[dt]
  if[not (`$sd:string dt) in key hdbdir;.z.m.log[`info][`cleanhdb;"Date ",sd," not in HDB."];:()];
  delpaths:1_'string .Q.par[hdbdir;dt;] each $[`all~first tablelist;enlist `;tablestoreplay];
  {.z.m.log[`info][`cleanhdb;"Deleting ",x," from HDB."];system"rm -r ",x} each delpaths;
 };

// Replay log file, if file is zipped and the kdb+ version is at least 4.0 then replay through named pipe
replayinner:{[msgnum;logfile]
  if[not zipped;-11!(msgnum;logfile);:()];
  if[not .z.o like "l*";.z.m.log[`error][`replaylog;m:"Zipped log files can only be directly replayed on Linux systems"];'m];
  if[.z.K<4.0;.z.m.log[`error][`replaylog;m:"Zipped log files can only be directly replayed on kdb+ 4.0 or higher"];'m];

  .z.m.log[`info][`replay;"Replaying logfile ",(f:1_string logfile)," over named pipe"];
  -11!(msgnum;hsym `$fifo:readintofifo f);
  system "rm -f ",fifo;
  .z.m.zipped:0b;
 };

// Create FIFO and unzip file into it, return FIFO name
readintofifo:{[filename]
  fifo:"/tmp/logfifo",string .z.i;
  fifostr:"mkfifo ",fifo,";gunzip -cd ",filename," > ",fifo," &";
  @[system;fifostr;{.z.m.log[`error][`replay;"Failed to read log into named pipe"]}];
  fifo
 };

// upd functions down here
applyupd:{[f;t;x]
	// increment the tablecounts
        .z.m.tablecounts[t]+:count first x;
	// run the supplied function in the error trap
	.[f;(t;x);{[t;x;e] .z.m.errorcounts[t]+:count first x}[t;x]];
	}

initialupd:{[t;x]
	 // spin through the first X messages
	 $[msgcount < (firstmessage - 1);
	.z.m.msgcount+:1;
	// Once we reach the correct message, reset the upd function
	@[`.;`upd;:;realupd]]
	}

// extract user defined row counts
mergemaxrows:{[tabname] mergenumrows^mergenumtab[tabname]};

// post replay function for merge replay, invoked after all the tables have been written down for a given log file
postreplaymerge:{[td;p;h]
 .z.m.os[`mkdir] .Q.par[td;p;`]; // ensures directory exists before removed
 mergelimits:(tabsincountorder[tablestoreplay],())!$[.z.m.merge.getmergebybytelimit[];(count tabsincountorder[tablestoreplay])#mergenumbytes;({[x] mergenumrows^mergemaxrows[x]}tabsincountorder[tablestoreplay])],();
 // merge the tables from each partition in the tempdir together
 mergetable[td;p;;mergelimits;h] each tabsincountorder[tablestoreplay];
 system"rm -r ",1_string .Q.par[td;p;`]; // delete the contents of tempdir after merge completion
 }

// function to upsert to specified directory
upserttopartition:{[h;dir;tablename;tabdata;pt;expttype;expt]
 dirpar:.Q.par[dir;pt;`$string first expt];
 directory:` sv dirpar,tablename,`;
 // make directories for tables if they don't exist
 if[count tabpar:tabsincountorder[tablestoreplay] except key dirpar;
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

savetablesbypart:{[dir;pt;tablename;h]
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
 upserttopartition[h;dir;tablename;enumdata;pt;extrapartitiontype] each extrapartitions;
 // empty the table
 .z.m.log[`info][`delete;"deleting ",(string tablename)," data from in-memory table"];
 @[`.;tablename;0#];
 // run a garbage collection (if enabled)
 if[gc;.z.m.dbw.gc[]];
 };


mergetable:{[dir;pt;tablename;mergelimits;h]
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
   [$[mergemethod~`part;
      [dest:` sv .Q.par[h;pt;tablename],`; // provides path to where to move data to
       /-get chunks to partitions to merge in batch
       partchunks:.z.m.merge.getpartchunks[partdirs;mergelimits[tablename]];
       .z.m.merge.mergebypart[.z.m.merge.getextrapartitiontype[.z.m.dbw.getconfig[];tablename];dest]'[partchunks];
      ];
      mergemethod~`col;
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
 if[gc;.z.m.dbw.gc[]];
 };

// Return log file if it exists and not in segmented mode
getlogfile:{
  if[segmentedmode;.z.m.log[`error][`getlogfile;m:"Segmented mode requires tplogdir."];'m];
  if[()~key hsym f:tplogfile;.z.m.log[`error][`getlogfile;m:"Specified tplogfile ",string[f]," does not exist"];'m];
  enlist hsym f
 };

// Return contents of log directory if it exists
getlogdir:{
  if[()~key hsym d:tplogdir;.z.m.log[`error][`getlogdir;m:"Specified log directory ",string[d]," does not exist"];'m];
  if[d like "*.gz";.z.m.log[`error][`getlogdir;m:"Zipped log directories not supported."];'m];
  $[segmentedmode;getstplogs[d];.Q.dd[logdir;] each key logdir:hsym d]
 };

// Use STP meta table and tplogdir to build log names
getstplogs:{[logdir]
  // If trying to replay zipped files on Windows, error out
  winzip:(.z.o like "w*") and z:`stpmeta.gz in key d:hsym logdir;
  if[winzip;.z.m.log[`error][`replaylog;m:"Zipped log files cannot be directly replayed on Windows"];'m];

  // If meta table is zipped, assume all other logs are zipped as well and build log names accordingly
  if[z;system "gunzip ",1_string .Q.dd[d;`stpmeta.gz]];
  metatable:@[get;.Q.dd[d;`stpmeta];{.z.m.log[`error][`getstpmeta;m:"Log directory must contain valid STP meta table"];'m}];
  if[z;system "gzip ",1_string .Q.dd[d;`stpmeta]];
  names:exec distinct logname from metatable where any each tbls in .z.m.tablestoreplay;
  .Q.dd[d;] each $[z;.Q.dd[;`gz];::] each last each ` vs' names
 };

// Set up log replay list and clean HDB if necessary, kick off replay
initandrun:{
  if[all not null (tplogfile;tplogdir);.z.m.log[`error][`getlogs;m:"Can't pass in log file and directory."];'m];

  .z.m.log[`info][`initandrun;"Initialising replay settings."];
  .z.m.tablestoreplay:$[`all~first tablelist;tables[];tablelist,()];
  .z.m.logstoreplay:$[not null tplogfile;getlogfile[];getlogdir[]];
  if[not count r:logstoreplay;.z.m.log[`error][`initandrun;m:"No log files found"];'m];

  // If in segmented mode, get replay date and clean HDB once
  if[segmentedmode;
    // Pull out the date from the STP log file name - *_YYYYMMDDhhmmss (+ .gz if zipped)
    .z.m.replaydate:first l:"D"$$[first[r] like "*.gz";-9_-17#;-6_-14#] each string r;
    if[not 1=count distinct l;.z.m.log[`error][`replay;m:"Cannot replay logs from different dates in segmented mode!"];'m];
    if[clean;cleanhdb replaydate]
   ];


  // Replay all logs and exit
  .z.m.log[`info][`initandrun;"Replaying the following log(s): ",csv sv 1_'string logstoreplay];
  .z.m.pathlist:()!();
  replaylog each logstoreplay;
  if[sortafterreplay;applysortandattr[pathlist]];
  if[partandmerge;postreplaymerge[tempdir;replaydate;hdbdir]];
  .z.m.log[`info][`replay;"replay complete"];
  if[exitwhencomplete;exit 0];
 };
