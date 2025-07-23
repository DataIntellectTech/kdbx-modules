// ---- dataloader.q ---- A generic dataloader library

// Functions loads data in from delimited file, applies processing function, enumerates it then writes to db
.loader.loaddata:{[loadparams;rawdata]
    data:$[loadparams[`filename] in .loader.filesread;                                                      // Check if we have already read some data from this file. First row may contain the header information in both cases we want to return a table with the same column names
           flip loadparams[`headers]!(loadparams[`types];loadparams[`separator])0:rawdata;                  // If it hasn't been read then we have to just read it as a list of lists
           $[all (`$"," vs rawdata[0;]) in loadparams[`headers];                                            // It hasn't been seen - the first row may or may not be column headers
              (loadparams[`types];enlist loadparams[`separator])0:rawdata;
              flip loadparams[`headers]!(loadparams[`types];loadparams[`separator])0:rawdata]
           ];
    if[not loadparams[`filename] in .loader.filesread;.loader.filesread,::loadparams[`filename]];
    data:0!loadparams[`dataprocessfunc] . (loadparams;data);                                                // Do some optional extra processing
    data:.Q.en[loadparams $[`symdir in key loadparams;`symdir;`dbdir];data];                                // Enumerate the table - best to do this once
    .loader.writedatapartition[loadparams[`dbdir];;loadparams[`partitiontype];loadparams[`partitioncol];loadparams[`tablename];data] each distinct loadparams[`partitiontype]$data[loadparams`partitioncol];
    if[loadparams`gc; .Q.gc[]];                                                                             // Garbage collection
 };

.loader.writedatapartition:{[dbdir;partition;partitiontype;partitioncol;tablename;data]
    towrite:data where partition=partitiontype$data partitioncol;                                           // Sub-select the data to write
    writepath:` sv .Q.par[dbdir;partition;tablename],`;                                                     // Generate the write path
    .[upsert;(writepath;towrite);{'"failed to save table: ",x}];                                            // Splay the table - use an error trap
    .loader.partitions[writepath]:(tablename;partition);                                                    // Make sure the written path is in the partition dictionary
 };

// Adds compression, sorting and attributes selected
.loader.finish:{[loadparams]
    if[count loadparams `compression;.z.zd:loadparams`compression];                                         // Set .z.zd
    {.loader.util.sorttab (x;where .loader.partitions[;0]=x)} each distinct value .loader.partitions[;0];   // Re-sort and set attributes on each partition
    system"x .z.zd";                                                                                        // Unset .z.zd
    if[loadparams`gc; .Q.gc[]];                                                                             // Garbage collection
 };

// Load all the files from a specified directory
.loader.loadallfiles:{[loadparams:.loader.util.paramfilter;dir]
    .loader.partitions::()!();                                                                              // Reset the partitions and files read variables
    .loader.filesread::();
    filelist:$[`filepattern in key loadparams;
               (key dir:hsym dir) where max like[key dir;] each loadparams[`filepattern];
               key dir:hsym dir];                                                                            // Get the contents of the directory based on optional filepattern
    filelist:` sv' dir,'filelist;                                                                            // Create the full path
    {[loadparams;file]
        .Q.fsn[.loader.loaddata[loadparams,(enlist`filename)!enlist file];file;loadparams`chunksize]
    }[loadparams] each filelist;
    .loader.finish[loadparams];                                                                              // Finish the load
 };

// Utility Functions
.loader.util.applyattr:{[dloc;colname;att]
    .[{@[x;y;z#]};(dloc;colname;att);                                                                        //  Attempt to apply the attribute to the column and log an error if it fails
      {[dloc;colname;att;e]
          '"unable to apply ",string[att]," attr to the ",string[colname]," column in the this directory : ",string[dloc],". The error was : ",e;
      }[dloc;colname;att]
     ]
 };

// Function used to sort and apply attributes to tables on disk based on format provided at initialisation of package.
.loader.util.sorttab:{[d]
    if[1>sum exec sort from .loader.sortparams;:()];
    sp:$[count tabparams:select from .loader.sortparams where tabname=d[0];
         tabparams;
         count defaultparams:select from .loader.sortparams where tabname=`default;
         defaultparams
        ];
    {[sp;dloc]                                                                                              // Loop through each directory and sort the data
        if[count sortcols: exec column from sp where sort, not null column;
           .[xasc;(sortcols;dloc);{[sortcols;dloc;e] '"failed to sort ",string[dloc]," by these columns : ",(", " sv string sortcols),".  The error was: ",e}[sortcols;dloc]]];
        if[count attrcols: select column, att from sp where not null att;
           .loader.util.applyattr[dloc;;]'[attrcols`column;attrcols`att]];                                  // Apply attribute(s)
    }[sp] each distinct (),last d;
 };

// Function checks keys are correct and value have the right types for loader.loadallfiles argument
.loader.util.paramfilter:{[loadparams]
    if[not 99h=type loadparams; '".loader.loadallfiles requires a dictionary parameter"];                   // Check the input
    req:`headers`types`tablename`dbdir`separator;                                                           // Required fields
    if[not all req in key loadparams;
       '"loaddata requires a dictionary parameter with keys of ",(", " sv string req)," : missing ",", " sv string req except key loadparams];
    if[not count loadparams `symdir;loadparams[`symdir]:loadparams[`dbdir]];
    loadparams:(`dataprocessfunc`chunksize`partitioncol`partitiontype`compression`gc!({[x;y] y};`int$100*2 xexp 20;`time;`date;();0b)),loadparams; // Join the loadparams with some default values
    reqtypes:`headers`types`tablename`dbdir`symdir`chunksize`partitioncol`partitiontype`gc!`short$(11;10;-11;-11;-11;-6;-11;-11;-1);               // Required types n
    if[count w:where not (type each loadparams key reqtypes)=reqtypes;                                     // Check the types
       '"incorrect types supplied for ",(", " sv string w)," parameter(s). Required type(s) are ",", " sv string reqtypes w];
    if[not 10h=abs type loadparams`separator;'"separator must be a character or enlisted character"];
    if[not 99h<type loadparams`dataprocessfunc;'"dataprocessfunc must be a function"];
    if[not loadparams[`partitiontype] in `date`month`year`int;'"partitiontype must be one of `date`month`year`int"];
    if[not count[loadparams`headers]=count loadparams[`types] except " ";'"headers and non-null separators must be the same length"];
    if[c:count loadparams[`compression]; if[not (3=c) and type[loadparams[`compression]] in 6 7h; '"compression parameters must be a 3 item list of type int or long"]];
    if[(`filepattern in key loadparams) & 10h=type loadparams[`filepattern];                              // If a filepattern was specified ensure that it's a list
       loadparams[`filepattern]:enlist loadparams[`filepattern]];
    loadparams
 };

// Function checks dictionary argument for init function has correct headers and types
.loader.util.sortfilter:{[sortparams]
    if[not 99h=type sortparams; '".loader.init requires a dictionary parameter"];
    if[not (abs type each value sortparams)~11 11 11 1h;'"Error, ensure dictionary values are the correct types 11 11 11 1h or -11 -11 -11 -1h"];
    if[not `tabname`att`column`sort~key sortparams; '"Error ensure argument is a dictionary with keys `tabname`att`column`sort"];
    flip (),/: sortparams
 };

// Initialisation function
.loader.init:{[sortparams:.loader.util.sortfilter]
    .loader.partitions:()!();                                                                              // Maintain a dictionary of the db partitions which have been written to by the loader
    .loader.filesread:();                                                                                  // Maintain a list of files which have been read
    .loader.sortparams:sortparams;
 };

