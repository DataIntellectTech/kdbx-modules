applyattr:{[dloc;colname;att]
  .[{@[x;y;z#]};(dloc;colname;att);                                                             / Attempt to apply the attribute to the column
  {[dloc;colname;att;e]
    '"unable to apply ",string[att]," attr to the ",string[colname]," column in the this directory : ",string[dloc],". The error was : ",e;
  }[dloc;colname;att]
  ]
  };

// Function used to sort and apply attributes to tables on disk based on format provided at initialisation of package.
sorttab:{[sortparams;d]
  if[1>sum exec sort from sortparams;:()];
  sp:$[count tabparams:select from sortparams where tabname=d[0];
    tabparams;
    count defaultparams:select from sortparams where tabname=`default;
    defaultparams
    ];
  {[sp;dloc]                                                                                    / Loop through each directory and sort the data
    if[count sortcols:exec column from sp where sort,not null column;
      .[xasc;(sortcols;dloc);{[sortcols;dloc;e]'"failed to sort ",string[dloc]," by these columns : ",(", " sv string sortcols),".  The error was: ",e}[sortcols;dloc]]];
    if[count attrcols:select column,att from sp where not null att;
      applyattr[dloc]'[attrcols`column;attrcols`att]];                                          / Apply attribute(s)
  }[sp]each distinct(),last d;
 };

// Function checks keys are correct and value have the right types for loadallfiles argument
paramfilter:{[loadparams]
  if[not 99h=type loadparams;'"loadallfiles requires a dictionary parameter"];                  / Check the input
  req:`headers`types`tablename`dbdir`separator;                                                 / Required fields
  if[not all req in key loadparams;
     '"loaddata requires a dictionary parameter with keys of ",(", " sv string req)," : missing ",", " sv string req except key loadparams];
  if[not count loadparams`symdir;loadparams[`symdir]:loadparams`dbdir];
  loadparams:(`dataprocessfunc`chunksize`partitioncol`partitiontype`compression`gc!({[x;y] y};`int$100*2 xexp 20;`time;`date;();0b)),loadparams; / Join the loadparams with some default values
  reqtypes:`headers`types`tablename`dbdir`symdir`chunksize`partitioncol`partitiontype`gc!11 10 -11 -11 -11 -6 -11 -11 -1h; / Required types n
  if[count w:where not(type each loadparams key reqtypes)=reqtypes;                             / Check the types
     '"incorrect types supplied for ",(", " sv string w)," parameter(s). Required type(s) are ",", " sv string reqtypes w];
  if[not 10h=abs type loadparams`separator;'"separator must be a character or enlisted character"];
  if[not 99h<type loadparams`dataprocessfunc;'"dataprocessfunc must be a function"];
  if[not loadparams[`partitiontype]in`date`month`year`int;'"partitiontype must be one of `date`month`year`int"];
  if[not count[loadparams`headers]=count loadparams[`types]except" ";'"headers and non-null separators must be the same length"];
  if[c:count loadparams`compression;if[not(3=c)and type[loadparams`compression]in 6 7h;'"compression parameters must be a 3 item list of type int or long"]];
  if[(`filepattern in key loadparams)& 10h=type loadparams`filepattern;                         / If a filepattern was specified ensure that it's a list
     loadparams[`filepattern]:enlist loadparams`filepattern];
  loadparams
 };

export:.z.m;
