/ header to build deserialisable msg
header:8#-8!(`upd;`trade;());			
/ first part of tp update msg
updmsg:`char$10#8_-8!(`upd;`trade;());	
/ size of default chunk to read (10MB)
chunk:10*1024*1024;					
/ don't let single read exceed this
maxchunk:8*chunk;						

check:{[logfile;lastmsgtoreplay]
  / logfile (symbol) is the handle to the logsfile
  / lastmsgtoreplay (long) is index position of the last message to be replayed from the log
  / check if the logfile is corrupt
  loginfo:-11!(-2;logfile);
  :$[1 = count loginfo;
  / - the log file is good so return the good log file handle
  :logfile;
  loginfo[0] <= lastmsgtoreplay + 1;
  :logfile;
  repair[logfile]
   ]
	};
	
repair:{[logfile]
	/ - append ".good" to the "good" log file
	goodlog: `$ string[logfile],".good";
	/ - create file and open handle to it
	goodlogh: hopen goodlog set ();
	/ - loop through the file in chunks
	repairover[logfile;goodlogh] over `start`size!(0j;chunk);
	/ - return goodlog
	goodlog
	};

repairover:{[logfile;goodlogh;d]
  / logfile (symbol) is the handle to the logsfile
  / goodlogh (int) is  the handle to the "good" log file
  / d (dictionary) has two keys start and size, the point to start reading from and size of chunk to read
  / read <size> bytes from <start>
  x:read1 logfile,d`start`size;		
  / find the start points of upd messages	
  u: ss[`char$x;updmsg];
  / nothing in this block 					
  if[not count u;		
	/ EOF - we're done
    if[hcount[logfile] <= sum d`start`size;:d];	
	/ move on <size> bytes
	:@[d;`start;+;d`size]];		
  / split bytes into msgs		
  m: u _ x;						
  / message sizes as bytes		
  mz: 0x0 vs' `int$ 8 + ms: count each m;	
  / set msg size at correct part of hdr
  hd: @[header;7 6 5 4;:;] each mz;		
  / try and deserialize each msg
  g: @[(1b;)@-9!;;(0b;)@] each hd,'m;	
  / write good msgs to the "good" log 	
  goodlogh g[;1] where k:g[;0];	
  / saw msg(s) but couldn't read		
  if[not any k;		
	/ read as much as we dare, give up
    if[maxchunk <= d`size;				
	  :@[d;`start`size;:;(sum d`start`size;chunk)]];
	/ read a bigger chunk
	:@[d;`size;*;2]];					
  / move to the end of the last good msg
  ns: d[`start] + sums[ms] last where k;	
  :@[d;`start`size;:;(ns;chunk)];       
 };

export:([check;repair])

