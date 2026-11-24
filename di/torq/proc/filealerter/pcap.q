/ pcap version 2.4 decoder for processpcaps, ported from TorQ/code/filealerter/pcapdecoder.q
/ file layout: https://www.kroosec.com/2012/10/a-look-at-pcap-file-format.html

/ size in bytes of the global header and of each packet header
globheader:24;
packetheader:16;

/ protocol id to name; add an id here for the decoder to translate it
allcodes:(enlist 6)!enlist `TCP;

/ the packets in a pcap file as a table, time and sym first; logs and returns () if the file is not pcap 2.4
buildtable:{[file]
  if[not all 2 0 4 0=read1(file;4;4);
    .z.m.log[`info][`buildtable;"pcap version number of ",(1_string file)," is incorrect, so could not be decoded"];
    :()];
  / scan gettablerow over each packet; the seed (0;1) and its row are dropped
  data:1_last each {[fb] gettablerow[fb;]\[{y>(first x 0)+40}[;count fb];(),0,1]} read1 file;
  data:update sym:` from data;
  `time`sym xcols data
  };

/ one packet: x is (start byte;latest window scale factor;row); returns the next packet's (start;scale;row)
gettablerow:{[fb;x]
  time:gettime[fb;x];
  ips:getips[fb;x];
  flags:getflags[fb;x];
  wsf:$[`SYN in flags;"i"$2 xexp fb globheader+packetheader+x[0]+75;x 1];
  info:getinfo[fb;x;flags;wsf];
  totallength:0x0 sv datafromfile[fb;x;18;2];
  ipheader:4*"J"$last string fb x[0]+globheader+packetheader+16;
  tcpheader:4*first "0123456789abcdef"?/:string fb x[0]+globheader+packetheader+48;
  len:(first first totallength-ipheader+tcpheader) mod 65536;
  length:(0x0 sv reverse fb x[0]+36 37) mod 65536;
  data:datafromfile[fb;x;length-len;len];
  row:`time xcols ips,info,`time`flags`protocol`length`len`data!(time;flags;getprotocol[fb;x];length;len;data);
  (x[0]+length+16;wsf;row)
  };

/ packet timestamp from its header
gettime:{[fb;x] first linuxtokdbtime ("iiii";4 4 4 4)1: packetheader#(globheader+x 0)_fb};

/ (seconds;microseconds) since the unix epoch to a timestamp
linuxtokdbtime:{[t] "p"$1000*t[1]+1000000*t[0]-10957*86400};

/ n bytes from offset start within the packet at x
datafromfile:{[fb;x;start;n] n#(globheader+packetheader+x[0]+start)_fb};

/ tcp flags set in the flag byte
getflags:{[fb;x]
  b:2 vs fb globheader+packetheader+x[0]+49;
  `CWR`ECE`URG`ACK`PSH`RST`SYN`FIN where ((8-count b)#0),b
  };

/ the protocol name, or its id if not in allcodes
getprotocol:{[fb;x]
  c:"i"$fb globheader+packetheader+x[0]+25;
  $[c in key allcodes;allcodes c;c]
  };

/ ports, sequence numbers, window (scaled unless a SYN) and timestamps from the tcp header
getinfo:{[fb;x;flags;wsf]
  e:first each (2 2 4 4 2 2 8 4 4;"hhii h ii")1: datafromfile[fb;x;36;32];
  / unsigned values read as signed are wrapped back into range
  e[0 1 4]:e[0 1 4] mod 65536;
  e[2 3 5 6]:e[2 3 5 6] mod 4294967296;
  if[not `SYN in flags;e[4]:e[4]*wsf];
  `srcport`destport`seq`ack`win`tsval`tsecr!e
  };

/ source and destination addresses as dotted-quad symbols
getips:{[fb;x] `src`dest!`$"." sv' string 4 cut "i"$datafromfile[fb;x;28;8]};
