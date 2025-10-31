/ generic dataloader library

/ loads data in from delimited file, applies processing function, enumerates and writes to db. NOTE: it is not trivial to check user has inputted headers correctly, assume they have
loaddata:{[loadparams;rawdata]
  / check if first row matches headers provided
  data:$[(`$"," vs rawdata 0)~loadparams`headers;
    (loadparams`types`separator)0:rawdata;
    flip loadparams[`headers]!(loadparams`types`separator)0:rawdata
    ];
  if[not loadparams[`filename]in filesread;filesread,:loadparams`filename];
  data:0!loadparams[`dataprocessfunc].(loadparams;data);
  / if enumname provided, use it, otherwise default to `sym
  domain:(`sym;loadparams`enumname)`enumname in key loadparams;
  data:.Q.ens[loadparams(`dbdir`symdir)`symdir in key loadparams;data;domain];
  wd:writedatapartition[data]. loadparams`dbdir`partitiontype`partitioncol`tablename;
  / run the writedatapartition function for each partition
  wd each distinct loadparams[`partitiontype]$data loadparams`partitioncol;
  if[loadparams`gc;.Q.gc[]];
  };

/ write data for provdided database and partition
writedatapartition:{[data;dbdir;partitiontype;partitioncol;tablename;partition]
  towrite:data where partition=partitiontype$data partitioncol;
  writepath:` sv .Q.par[dbdir;partition;tablename],`;
  .[upsert;(writepath;towrite);{'"failed to save table: ",x}];
  .z.m.partitions[writepath]:(tablename;partition);
  };

/ adds compression, sorting and attributes selected
finish:{[loadparams]
  / temporarily set compression defaults
  if[count loadparams`compression;.z.zd:loadparams`compression];
  {util.sorttab[sp](x;where partitions[;0]=x)}each distinct value partitions[;0];
  system"x .z.zd";
  if[loadparams`gc;.Q.gc[]];
  };

/ load all the files from a specified directory
loadallfiles:{[loadparams:util.paramfilter;dir]
  .z.m.partitions:()!();
  .z.m.filesread:();
  / get the contents of the directory based on optional filepattern
  filelist:$[`filepattern in key loadparams;
    key[dir:hsym dir]where key[dir]like first loadparams`filepattern;
    key dir:hsym dir];
  filelist:` sv'dir,'filelist;
  {[loadparams;file].Q.fsn[loaddata loadparams,(enlist`filename)!enlist file;file;loadparams`chunksize]}[loadparams]each filelist;
  finish loadparams;
  };

/ set default sorting parameters
sp:flip`tabname`att`column`sort!(1#`default;`p;`sym;1b);
sortparams:{[]sp};

/ add custom sorting parameters to the sortparams table
addsortparams:{[tabname;att;column;sort]
  x:flip(flip sortparams[]),'(tabname;att;column;sort);
  .z.m.sp:select from x where i=(last;i)fby tabname;
  };
