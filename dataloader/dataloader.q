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
  partitions[writepath]:(tablename;partition);
  };

finish:{[loadparams]
  / adds compression, sorting and attributes selected
  if[count loadparams `compression;.z.zd:loadparams`compression]; / temporarily set compression defaults
  {sorttab (x;where partitions[;0]=x)} each distinct value partitions[;0];
  system"x .z.zd";
  if[loadparams`gc; .Q.gc[]];
  };

loadallfiles:{[loadparams:paramfilter;dir]
  / load all the files from a specified directory
  partitions::()!();
  filesread::();
  filelist:$[`filepattern in key loadparams;
    (key dir:hsym dir) where max like[key dir;] each loadparams[`filepattern];
    key dir:hsym dir]; / get the contents of the directory based on optional filepattern
  filelist:` sv' dir,'filelist;
  {[loadparams;file] .Q.fsn[loaddata[loadparams,(enlist`filename)!enlist file];file;loadparams`chunksize]}[loadparams] each filelist;
  finish[loadparams];
  };

applyattr:{[dloc;colname;att]
  / utility function
  .[{@[x;y;z#]};(dloc;colname;att);
    {[dloc;colname;att;e]
      '"unable to apply ",string[att]," attr to the ",string[colname]," column in the this directory : ",string[dloc],". The error was : ",e;
    }[dloc;colname;att]
    ]
  };

sorttab:{[d]
  / function used to sort and apply attributes to tables on disk based on format provided at initialisation of package.
  if[1>sum exec sort from sortparams;:()];
  sp:$[count tabparams:select from sortparams where tabname=d[0];
    tabparams;
    count defaultparams:select from sortparams where tabname=`default;
    defaultparams
    ];
  {[sp;dloc] / loop through each directory and sort the data
    if[count sortcols: exec column from sp where sort, not null column;
      .[xasc;(sortcols;dloc);{[sortcols;dloc;e] '"failed to sort ",string[dloc]," by these columns : ",(", " sv string sortcols),".  The error was: ",e}[sortcols;dloc]]];
    if[count attrcols: select column, att from sp where not null att;
      applyattr[dloc;;]'[attrcols`column;attrcols`att]]; / apply attributes
  }[sp] each distinct (),last d;
  };

paramfilter:{[loadparams]
  / function checks keys are correct and value have the right types for loadallfiles argument
  if[not 99h=type loadparams; '"loadallfiles requires a dictionary parameter"];
  req:`headers`types`tablename`dbdir`separator;
  if[not all req in key loadparams;
    '"loaddata requires a dictionary parameter with keys of ",(", " sv string req)," : missing ",", " sv string req except key loadparams];
  if[not count loadparams `symdir;loadparams[`symdir]:loadparams[`dbdir]];
  loadparams:(`dataprocessfunc`chunksize`partitioncol`partitiontype`compression`gc!({[x;y] y};`int$100*2 xexp 20;`time;`date;();0b)),loadparams; / join loadparams with some default values
  reqtypes:`headers`types`tablename`dbdir`symdir`chunksize`partitioncol`partitiontype`gc!`short$(11;10;-11;-11;-11;-6;-11;-11;-1);
  if[count w:where not (type each loadparams key reqtypes)=reqtypes;
    '"incorrect types supplied for ",(", " sv string w)," parameter(s). Required type(s) are ",", " sv string reqtypes w];
  if[not 10h=abs type loadparams`separator;'"separator must be a character or enlisted character"];
  if[not 99h<type loadparams`dataprocessfunc;'"dataprocessfunc must be a function"];
  if[not loadparams[`partitiontype] in `date`month`year`int;'"partitiontype must be one of `date`month`year`int"];
  if[not count[loadparams`headers]=count loadparams[`types] except " ";'"headers and non-null separators must be the same length"];
  if[c:count loadparams[`compression]; if[not (3=c) and type[loadparams[`compression]] in 6 7h; '"compression parameters must be a 3 item list of type int or long"]];
  if[not `enumname in key loadparams;loadparams[`enumname]:`sym];
  if[(`filepattern in key loadparams) & 10h=type loadparams[`filepattern]; / ensure if specified that filepattern is a list
    loadparams[`filepattern]:enlist loadparams[`filepattern]];
  loadparams
  };

sortfilter:{[sortparams]
  / function checks dictionary argument for init function has correct headers and types
  if[not 99h=type sortparams; '"init requires a dictionary parameter"];
  if[not (abs type each value sortparams)~11 11 11 1h;'"Error ensure dictionary values are the correct types 11 11 11 1h or -11 -11 -11 -1h"];
  if[not `tabname`att`column`sort~key sortparams; '"Error ensure argument is a dictionary with keys `tabname`att`column`sort"];
  flip (),/: sortparams
  };

init:{[sp:sortfilter]
  / package init function
  `partitions set ()!(); / maintain a dictionary of the db partitions written to by loader
  `filesread set (); / maintain a list of files which have been read
  `sortparams set sortparams;
  };
