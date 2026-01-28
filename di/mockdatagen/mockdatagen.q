\p 5067
\g 1

initschema:{[]
  .z.m.trades:([] time:`timestamp$(); sym:`g#`$(); src:`g#`$(); price:`float$(); size:`int$());
  .z.m.quotes:([] time:`timestamp$(); sym:`g#`$(); src:`g#`$(); bid:`float$(); ask:`float$(); bsize:`int$(); asize:`int$());
  .z.m.depth:([] time:`timestamp$(); sym:`g#`$(); bid1:`float$(); bsize1:`int$(); bid2:`float$(); bsize2:`int$(); bid3:`float$(); bsize3:`int$(); bid4:`float$(); bsize4:`int$(); bid5:`float$(); bsize5:`int$(); ask1:`float$(); asize1:`int$(); ask2:`float$(); asize2:`int$(); ask3:`float$(); asize3:`int$(); ask4:`float$(); asize4:`int$(); ask5:`float$(); asize5:`int$());
  };

/ utility Functions
rnd:{0.01*floor 100*x};

cleartables:{[]
   initschema[];
 };

/ funtion to generate mock data for a single symbol/instrument
mockdataone:{[sym;date;starttime;endtime;rowCnt;startPx;level]
  -1"Generating data for ",string[sym]," for date: ",string[date];
  daternd:2+date mod  7;
  tradecnt:floor(100+daternd)*rowCnt%100;
  quotecnt:(19+daternd)*tradecnt;
  depthcnt:(97+daternd)*tradecnt;
  -1"Trade rows: ",string[tradecnt],"\t Quote rows: ",string[quotecnt],"\t Depth Rows: ",string[depthcnt];
  hoursinday:endtime-starttime;
  t0:date+starttime;
  t1:date+endtime;
  ttimes:date+ `#asc starttime+tradecnt?hoursinday;
  qtimes:date+ `#asc starttime+quotecnt?hoursinday;
  mids:startPx* exp sums 0.0005*-1+quotecnt?2f;
  mids:0.01*floor 100*mids;
  bid:rnd mids-quotecnt?0.03;
  ask:rnd mids+quotecnt?0.03;
  bsize:`int$(600*1+quotecnt?20);
  asize:`int$(600*1+quotecnt?20);
  tradeidx:til tradecnt;
  quoteidx:5*tradeidx;
  side:tradecnt?`buy`sell;
  price:0.01*floor 100*?[side=`buy; ask[quoteidx]; bid[quoteidx]];
  tsize:`int$((tradecnt?1f)*?[side=`buy; asize[quoteidx]; bsize[quoteidx]]);
  .z.m.trades,:flip `time`sym`src`price`size!(ttimes;tradecnt#sym;tradecnt?`N`O`L;price;tsize);
  .z.m.quotes,:flip `time`sym`src`bid`ask`bsize`asize!(qtimes;quotecnt#sym;quotecnt?`N`O`L;bid;ask;bsize;asize);
  if[level=2;
  dtimes:date+ `#asc starttime+depthcnt?hoursinday;
  dIdx:(til depthcnt) mod quotecnt;
  dbid:bid[dIdx];dask:ask[dIdx];
  b1:`int$(600*1+depthcnt?20);b2:b1+`int$(600*1+depthcnt?5);b3:b1+`int$(600*1+depthcnt?10);b4:b1+`int$(600*1+depthcnt?15);b5:b1+`int$(600*1+depthcnt?20);
  a1:`int$(600*1+depthcnt?20);a2:a1+`int$(600*1+depthcnt?5);a3:a1+`int$(600*1+depthcnt?5);a4:a1+`int$(600*1+depthcnt?5);a5:a1+`int$(600*1+depthcnt?5);
  .z.m.depth,:flip `time`sym`bid1`bsize1`bid2`bsize2`bid3`bsize3`bid4`bsize4`bid5`bsize5`ask1`asize1`ask2`asize2`ask3`asize3`ask4`asize4`ask5`asize5!(dtimes;depthcnt#sym;dbid;b1;dbid-0.01;b2;dbid-0.02;b3;dbid-0.03;b4;dbid-0.04;b5;dask;a1;dask+0.01;a2;dask+0.02;a3;dask+0.03;a4;dask+0.04;a5);
  ];
  };

/ function to generate the mock data for multiple syms on a given date
mockdata:{[syms;date;starttime;endtime;rowcnts;startpxs;level]
  -1"Verifying inputs";
  if[not 11h=abs[type syms];-1"ERROR: Input tickers should be sym type";:()];
  syms:$[11h=type syms; syms; enlist syms];
  rc:$[99h=type rowcnts; rowcnts; (enlist syms)!enlist rowcnts];
  spx:$[99h=type startpxs; startpxs; (enlist syms)!enlist startpxs];
  {[s;rc;spx;date;starttime;endtime;level] 
   sp:$[`sp in key .z.m; $[null .z.m.sp[s]; spx[s]; .z.m.sp[s]]; spx[s]];
   mockdataone[s;date;starttime;endtime;rc[s];sp;level]}[;rc;spx;date;starttime;endtime;level] each syms;
   };

/ function to write the data down to HDB for the given date list
mockhdb:{[dir;syms;dates;starttime;endtime;rowcnts;startpxs;level]
  -1"Generating mock data for the following syms:";
  -1 " "sv string symlist;
  -1"And for the following dates";
  -1 " "sv string dates;
  cleartables[]; 
  {[dir;syms;d;starttime;endtime;rowcnts;startpxs;level]
   mockdata[syms;d;starttime;endtime;rowcnts;startpxs;level]; 
   .z.m.sp:syms!{last exec price from .z.m.trades where sym = x} each syms;
   `trades set .z.m.trades;
   `quotes set .z.m.quotes;
   `depth set .z.m.depth;
   .Q.hdpf[`:;dir;d;`sym]; cleartables[] }[dir;syms;;starttime;endtime;rowcnts;startpxs;level] each dates;
   .z.m.sp:syms!(count syms)#0nf;
  };
