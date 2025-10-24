/ generic dataloader library

loaddata:{[loadparams;rawdata]
  / loads data in from delimeted file, applies processing function, enumerates and writes to db
  data:$[loadparams[`filename] in filesread; / check if some data has already been read in
    flip loadparams[`headers]!(loadparams[`types];loadparams[`separator])0:rawdata;
    $[all (`$"," vs rawdata[0;]) in loadparams[`headers]; / it hasn't been seen, may be column headers
      (loadparams[`types];loadparams[`separator])0:rawdata;
      flip loadparams[`headers]!(loadparams[`types];loadparams[`separator])0:rawdata]
    ];
  if[not loadparams[`filename] in filesread;filesread,::loadparams[`filename]];
  .c.t:(loadparams;filesread);
  data:0!loadparams[`dataprocessfunc] . (loadparams;data);
  data:.Q.ens[loadparams $[`symdir in key loadparams;`symdir;`dbdir];data;loadparams[`enumname]];
  writedatapartition[loadparams[`dbdir];;loadparams[`partitiontype];loadparams[`partitioncol];loadparams[`tablename];data] each distinct loadparams[`partitiontype]$data[loadparams`partitioncol];
  if[loadparams`gc; .Q.gc[]];
  };

writedatapartition:{[dbdir;partition;partitiontype;partitioncol;tablename;data]
  / write data for provdided database and partition
  towrite:data where partition=partitiontype$data partitioncol;
  writepath:` sv .Q.par[dbdir;partition;tablename],`;
  .[upsert;(writepath;towrite);{'"failed to save table: ",x}];
  .z.m.partitions[writepath]:(tablename;partition);
  };

finish:{[loadparams]
  / adds compression, sorting and attributes selected
  if[count loadparams `compression;.z.zd:loadparams`compression]; / temporarily set compression defaults
  {.m.dataloader.util.sorttab (x;where .z.m.partitions[;0]=x)} each distinct value .z.m.partitions[;0];
  system"x .z.zd";
  if[loadparams`gc; .Q.gc[]];
  };

loadallfiles:{[loadparams:.m.dataloader.util.paramfilter;dir]
  / load all the files from a specified directory
  .z.m.partitions::()!();
  filesread::();
  filelist:$[`filepattern in key loadparams;
    (key dir:hsym dir) where max like[key dir;] each loadparams[`filepattern];
    key dir:hsym dir]; / get the contents of the directory based on optional filepattern
  filelist:` sv' dir,'filelist;
  {[loadparams;file] .Q.fsn[loaddata[loadparams,(enlist`filename)!enlist file];file;loadparams`chunksize]}[loadparams] each filelist;
  .z.m.finish[loadparams];
  };

init:{[sortparams:.m.dataloader.util.sortfilter]
  / package init function
  .z.m.partitions:()!(); / maintain a dictionary of the db partitions written to by loader
  .z.m.filesread:(); / maintain a list of files which have been read
  .z.m.sortparams:sortparams;
  };
