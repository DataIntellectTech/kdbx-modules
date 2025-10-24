/ generic dataloader library

loaddata:{[loadparams;rawdata]
  / loads data in from delimited file, applies processing function, enumerates and writes to db
  / NOTE: it is not trivial to check user has inputted headers correctly, assume they have
  data:$[(`$"," vs rawdata 0)~loadparams`headers;                                               / check if first row matches headers provided
    (loadparams`types`separator)0:rawdata;                                                      / if so, read in the files normally
    flip loadparams[`headers]!(loadparams`types`separator)0:rawdata                             / if not, add the headers manually
    ];
  if[not loadparams[`filename]in filesread;filesread,:loadparams`filename];                     / if we havent read this file before, add it to filesread
  data:0!loadparams[`dataprocessfunc].(loadparams;data);                                        / apply the user provided processing function to the data
  domain:(`sym;loadparams`enumname)`enumname in key loadparams;                                 / if enumname provided, use it, otherwise default to `sym
  data:.Q.ens[loadparams(`dbdir`symdir)`symdir in key loadparams;data;domain];                  / enumerate sym columns to given domain
  wd:writedatapartition[data]. loadparams`dbdir`partitiontype`partitioncol`tablename;           / create write down function using all the params
  wd each distinct loadparams[`partitiontype]$data loadparams`partitioncol;                     / run the writedatapartition function for each partition
  if[loadparams`gc;.Q.gc[]];
  };

writedatapartition:{[data;dbdir;partitiontype;partitioncol;tablename;partition]
  / write data for provdided database and partition
  towrite:data where partition=partitiontype$data partitioncol;
  writepath:` sv .Q.par[dbdir;partition;tablename],`;
  .[upsert;(writepath;towrite);{'"failed to save table: ",x}];
  .z.m.partitions[writepath]:(tablename;partition);
  };

finish:{[loadparams]
  / adds compression, sorting and attributes selected
  if[count loadparams`compression;.z.zd:loadparams`compression];                                / temporarily set compression defaults
  {.z.m.util.sorttab(x;where .z.m.partitions[;0]=x)}each distinct value .z.m.partitions[;0];
  system"x .z.zd";
  if[loadparams`gc;.Q.gc[]];
  };

loadallfiles:{[loadparams:.z.m.util.paramfilter;dir]
  / load all the files from a specified directory
  .z.m.partitions::()!();
  .z.m.filesread:();
  filelist:$[`filepattern in key loadparams;
    key[dir:hsym dir]where key[dir]like first loadparams`filepattern;
    key dir:hsym dir];                                                                          / get the contents of the directory based on optional filepattern
  filelist:` sv'dir,'filelist;
  {[loadparams;file].Q.fsn[loaddata[loadparams,(enlist`filename)!enlist file];file;loadparams`chunksize]}[loadparams]each filelist;
  .z.m.finish loadparams;
  };

init:{[sortparams:.z.m.util.sortfilter]
  / package init function
  .z.m.partitions:()!();                                                                        / maintain a dictionary of the db partitions written to by loader
  .z.m.filesread:();                                                                            / maintain a list of files which have been read
  .z.m.sortparams:sortparams;
  };
