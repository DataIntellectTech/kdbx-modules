checkcsv:{[csvtab;path]
  / validate config csv loaded by loadcsv function
  / include snappy (3) for version 3.4 or after
  allowedalgos:0 1 2,$[.z.K>=3.4;3;()];
  if[0b~all colscheck:`table`minage`column`calgo`cblocksize`clevel in (cols csvtab);
    log.error[err:path,": Compression config has incorrect column layout at column(s): ", (" " sv string where not colscheck), ". Should be `table`minage`column`calgo`cblocksize`clevel."];'err];
  if[count checkalgo:exec i from csvtab where not calgo in allowedalgos;
    log.error[err:path,": Compression config has incorrect compression algo in row(s): ",(", " sv string -1_allowedalgos)," or ",(string last allowedalgos),"."];'err];
  if[count checkblock:exec i from csvtab where calgo in 1 2, not cblocksize in 12 + til 9;
    log.error[err:path,": Compression config has incorrect compression blocksize at row(s): ", (" " sv string checkblock), ". Should be between 12 and 19."];'err];
  if[count checklevel: exec i from csvtab where calgo in 2, not clevel in til 10;
    log.error[err:path,": Compression config has incorrect compression level at row(s): ", (" " sv string checklevel), ". Should be between 0 and 9."];'err];
  if[.z.o like "w*"; if[count rowwin:where ((csvtab[`cblocksize] < 16) & csvtab[`calgo] > 0);
    log.error[err:path,": Compression config has incorrect compression blocksize for windows at row: ", (" " sv string rowwin), ". Must be more than or equal to 16."];'err]];
  if[(any nulls: any null (csvtab[`column];csvtab[`table];csvtab[`minage];csvtab[`clevel]))>0;
    log.error[err:path,": Compression config has empty cells in column(s): ", (" " sv string `column`table`minage`clevel where nulls)];'err];
  };

/ Empty compressioncsv table defined for edge case where a bad config is loaded first attempt
compressioncsv:([] table:`$();minage:`int$();column:`$();calgo:`int$();cblocksize:`int$();clevel:`int$());

loadcsv:{[inputcsv]
  / accepts hsym path as argument
  / loads and checks compression config
  loadedcsv:@[{log.info["Opening ", x];("SISIII"; enlist ",") 0:"S"$x}; (string inputcsv); {log.error["failed to open ", (x)," : ",y];'y}[string inputcsv]];
  res:.[checkcsv;(loadedcsv;string inputcsv);{log.error["failed to load csv due to error: ",x];:0b}];
  if[res~0b;:(::)];
  compressioncsv::loadedcsv;
  };

getcompressioncsv:{[] .z.m.compressioncsv};

traverse:{$[(0=count k)or x~k:key x; x; .z.s each ` sv' x,/:k where not any k like/:(".d";"*.q";"*.k";"*#")]};

hdbstructure:{
  t:([]fullpath:(raze/)traverse x); // orig traverse
  / calculate the length of the input path
  base:count "/" vs string x;
  / split out the full path
  t:update splitcount:count each split from update split:"/" vs' string fullpath,column:`,table:`,partition:(count t)#enlist"" from t;
  / partitioned tables
  t:update partition:split[;base],table:`$split[;base+1],column:`$split[;base+2] from t where splitcount=base+3;
  / splayed
  t:update table:`$split[;base],column:`$split[;base+1] from t where splitcount=base+2;
  / cast the partition type
  t:update partition:{$[not all null r:"D"$'x;r;not all null r:"M"$'x;r;"I"$'x]}[partition] from t;
  / work out the age of each partition
  $[14h=type t`partition; t:update age:.z.D - partition from t;
    13h=type t`partition; t:update age:(`month$.z.D) - partition from t;
    / otherwise it is ints.  If all the values are within 1000 and 3000
    / then assume it is years
    t:update age:{$[all x within 1000 3000; x - `year$.z.D;(count x)#0Ni]}[partition] from t];
  delete splitcount,split from t
  };

showcomp:{[hdbpath;csvpath;maxage]
  / load config from csvpath and display summary of files to be compressed and how
  / load csv
  loadcsv[$[10h = type csvpath;hsym `$csvpath;hsym csvpath]];
  log.info["compression: scanning hdb directory structure"];
  / build paths table and fill age
  $[count key (` sv hdbpath,`$"par.txt");
    pathstab:update 0W^age from (,/) hdbstructure'[hsym each `$(read0 ` sv hdbpath,`$"par.txt")];
    pathstab:update 0W^age from hdbstructure[hsym hdbpath]];
  / delete anything which isn't a table
  pathstab:delete from pathstab where table in `;
  / tables that are in the hdb but not specified in the csv - compress with `default params
  comptab:2!delete minage from update compressage:minage from .z.m.compressioncsv;
  / specified columns and tables
  a:select from comptab where not table=`default, not column=`default;
  / default columns, specified tables
  b:select from comptab where not table=`default,column=`default;
  / defaults
  c:select from comptab where table = `default, column =`default;
  / join on defaults to entire table
  t: pathstab,'(count pathstab)#value c;
  / join on for specified tables
  t: t lj 1!delete column from b;
  / join on table and column specified information
  t: t lj a;
  / in case of no default specified, delete from the table where no data is joined on
  t: delete from t where calgo=0Nj,cblocksize=0Nj,clevel=0Nj;
  log.info["compression: getting current size of each file up to a maximum age of ",string maxage];
  update currentsize:hcount each fullpath from select from t where age within (compressage;maxage)
  };

compressfromtable:{[table]
  statstab::([] file:`$(); algo:`int$(); compressedLength:`long$();uncompressedLength:`long$());
  / Check if process is single threaded - if multi then compress in parallel then clean up after
  / Add metrics on any files due to be compressed to be used afterwards for comparison 
  table:update compressionvaluepre:{(-21!x)`compressedLength}'[fullpath] from table;
  $[0= system"s";
    singlethreadcompress[table];
    multithreadcompress[table]];
  / Update the stats tab table after the compression 
  {statstabupdate[x`fullpath;x`calgo;x`currentsize;x`compressionvaluepre]} each table
  };

statstabupdate:{[file;algo;sizeuncomp;compressionvaluepre]
  if[not compressionvaluepre ~ (-21!file)`compressedLength;
    statstab,:
      $[not 0=algo;
        (file;algo;(-21!file)`compressedLength;sizeuncomp);
        (file;algo;compressionvaluepre;sizeuncomp)]
    ]
  };

singlethreadcompress:{[table]
  log.info["compression: Single threaded process, compress applied sequentially"];
  {compress[x `fullpath;x `calgo;x `cblocksize;x `clevel; x `currentsize];
    cleancompressed[x `fullpath;x `calgo]} each table;
  };
 
multithreadcompress:{[table]
  log.info["compression: Multithreaded process, compress applied in parallel "];
  {compress[x `fullpath;x `calgo;x `cblocksize;x `clevel; x `currentsize]} peach table;
  {cleancompressed[x `fullpath;x `calgo]} each table;
  };

compressmaxage:{[hdbpath;csvpath;maxage]
  / call the compression with a max age paramter implemented
  compressfromtable[showcomp[hdbpath;csvpath;maxage]];
  summarystats[];
  };

/ compression without a max age
docompression:compressmaxage[;;0W];

/ getter for post compression summary table
getstatstab:{[] .z.m.statstab};

summarystats:{
  /- table with compressionratio for each file
  statstab::`compressionratio xdesc (update compressionratio:?[algo=0; neg uncompressedLength%compressedLength; uncompressedLength%compressedLength] from statstab);
  compressedfiles: select from statstab where not algo = 0;
  decompressedfiles:select from statstab where algo = 0;
  /- summarytable
  memorysavings: ((sum compressedfiles`uncompressedLength) - sum compressedfiles`compressedLength) % 2 xexp 20;
  totalcompratio: (sum compressedfiles`uncompressedLength) % sum compressedfiles`compressedLength;
  memoryusage:((sum decompressedfiles`uncompressedLength) - sum decompressedfiles`compressedLength) % 2 xexp 20;
  totaldecompratio: neg (sum decompressedfiles`compressedLength) % sum decompressedfiles`uncompressedLength;
  log.info["compression: Memory savings from compression: ", .Q.f[2;memorysavings], "MB. Total compression ratio: ", .Q.f[2;totalcompratio],"."];
  log.info["compression: Additional memory used from de-compression: ",.Q.f[2;memoryusage], "MB. Total de-compression ratio: ", .Q.f[2;totaldecompratio],"."];
  log.info["compression: Check getstatstab[] for info on each file."];
  };

compress:{[filetoCompress;algo;blocksize;level;sizeuncomp]
  compressedFile: hsym `$(string filetoCompress),"_kdbtempzip";
  / compress or decompress as appropriate:
  cmp:$[algo=0;"de";""];
  $[((0 = count -21!filetoCompress) & not 0 = algo)|((not 0 = count -21!filetoCompress) & 0 = algo);
    [log.info["compression: ",cmp,"compressing ","file ", (string filetoCompress), " with algo: ", (string algo), ", blocksize: ", (string blocksize), ", and level: ", (string level), "."];
    / perform the compression/decompression
    -19!(filetoCompress;compressedFile;blocksize;algo;level);
    ];
    / if already compressed/decompressed, then log that and skip.
    log.info["compression: file ", (string filetoCompress), " is already ",cmp,"compressed",". Skipping this file"]
  ]
  };

cleancompressed:{[filetoCompress;algo]
  compressedFile: hsym `$(string filetoCompress),"_kdbtempzip";
  cmp:$[algo=0;"de";""];
  / Verify compressed file exists 
  if[()~ key compressedFile;
    log.info["compression: No compressed file present for the following file - ",string[filetoCompress]];
    :();
   ];
  / Verify compressed file's contents match original
  if[not ((get compressedFile)~sf:get filetoCompress) & (count -21!compressedFile) or algo=0;
     log.info["compression: ",cmp,"compressed ","file ",string[compressedFile]," doesn't match original. Deleting new file"];
     hdel compressedFile;
     :();
   ];
  / Given above two checks satisfied run the delete of old and rename compressed to original name 
  log.info["compression: File ",cmp,"compressed ",string[filetoCompress]," successfully; matches orginal. Deleting original."];
  system "r ", (last ":" vs string compressedFile)," ", last ":" vs string filetoCompress;
  / move the hash files too.
  hashfilecheck[compressedFile;filetoCompress;sf];
  };


hashfilecheck:{[compressedFile;filetoCompress;sf]
  / if running 3.6 or higher, account for anymap type for nested lists
  / check for double hash file if nested data contains symbol vector/atom
  $[3.6<=.z.K;
    if[77 = type sf; system "r ", (last ":" vs string compressedFile),"# ", (last ":" vs string filetoCompress),"#";
      .[{system "r ", (last ":" vs string x),"## ", (last ":" vs string y),"##"};(compressedFile;filetoCompress);log.info["compression: File does not have enumeration domain"]]];
    / if running below 3.6, nested list types will be 77h+t and will not have double hash file    
    if[78 <= type sf; system "r ", (last ":" vs string compressedFile),"# ", (last ":" vs string filetoCompress),"#"]
  ]
  };
