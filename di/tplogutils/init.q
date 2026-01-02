HEADER: 8 # -8!(`upd;`trade;());			/ - header to build deserialisable msg
UPDMSG: `char$10 # 8 _ -8!(`upd;`trade;());	/ - first part of tp update msg
CHUNK: 10 * 1024 * 1024;					/ - size of default chunk to read (10MB)
MAXCHUNK: 8 * CHUNK;						/ - don't let single read exceed this

check: {[logfile;lastmsgtoreplay]
	/ - logfile (symbol) is the handle to the logsfile
	/ - lastmsgtoreplay (long) is index position of the last message to be replayed from the log
	/ - check if the logfile is corrupt
	loginfo: -11!(-2;logfile);
	:$[ 1 = count loginfo;
		/ - the log file is good so return the good log file handle
		:logfile;
	loginfo[0] <= lastmsgtoreplay + 1;
		:logfile;
		repair[logfile]
	]
	};
	
repair: {[logfile]
	/ - append ".good" to the "good" log file
	goodlog: `$ string[logfile],".good";
	/ - create file and open handle to it
	goodlogh: hopen goodlog set ();
	/ - loop through the file in chunks
	repairover[logfile;goodlogh] over `start`size!(0j;CHUNK);
	/ - return goodlog
	goodlog
	};
	
repairover: {[logfile;goodlogh;d]
	/ - logfile (symbol) is the handle to the logsfile
	/ - goodlogh (int) is  the handle to the "good" log file
	/ - d (dictionary) has two keys start and size, the point to start reading from and size of chunk to read
	x:read1 logfile,d`start`size;			/ - read <size> bytes from <start>
	u: ss[`char$x;UPDMSG];					/ - find the start points of upd messages
	if[not count u;							/ - nothing in this block 
		if[hcount[logfile] <= sum d`start`size;:d];	/ - EOF - we're done
		:@[d;`start;+;d`size]];				/ - move on <size> bytes
	m: u _ x;								/ - split bytes into msgs
	mz: 0x0 vs' `int$ 8 + ms: count each m;	/ - message sizes as bytes
	hd: @[HEADER;7 6 5 4;:;] each mz;		/ - set msg size at correct part of hdr
	g: @[(1b;)@-9!;;(0b;)@] each hd,'m;		/ - try and deserialize each msg
	goodlogh g[;1] where k:g[;0];			/ - write good msgs to the "good" log 
	if[not any k;							/ - saw msg(s) but couldn't read
		if[MAXCHUNK <= d`size;				/ - read as much as we dare, give up
			:@[d;`start`size;:;(sum d`start`size;CHUNK)]];
		:@[d;`size;*;2]];					/ - read a bigger chunk
	ns: d[`start] + sums[ms] last where k;	/ - move to the end of the last good msg
	:@[d;`start`size;:;(ns;CHUNK)];       
	};

export:([check;repair;repairover])

