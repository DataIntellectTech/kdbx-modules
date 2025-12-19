initschema:{[]
  .z.m.trades:([] time:`timestamp$(); sym:`g#`$(); src:`g#`$(); price:`float$(); size:`int$());
  .z.m.quotes:([] time:`timestamp$(); sym:`g#`$(); src:`g#`$(); bid:`float$(); ask:`float$(); bsize:`int$(); asize:`int$());
  .z.m.depth:([] time:`timestamp$(); sym:`g#`$(); bid1:`float$(); bsize1:`int$(); bid2:`float$(); bsize2:`int$(); bid3:`float$(); bsize3:`int$(); bid4:`float$(); bsize4:`int$(); bid5:`float$(); bsize5:`int$(); ask1:`float$(); asize1:`int$(); ask2:`float$(); asize2:`int$(); ask3:`float$(); asize3:`int$(); ask4:`float$(); asize4:`int$(); ask5:`float$(); asize5:`int$());
  };

// Utility Functions
rnd:{0.01*floor 100*x};

clearTables:{[]
   initschema[];
 };

// funtion to generate mock data for a single symbol/instrument
mockDataOne:{[sym;date;startTime;endTime;rowCnt;startPx;level]
  tradeCnt:rowCnt;
  quoteCnt:5*tradeCnt;
  hoursinday:endTime-startTime;
  t0:date+startTime;
  t1:date+endTime;
  ttimes:date+ `#asc startTime+tradeCnt?hoursinday;
  qtimes:date+ `#asc startTime+quoteCnt?hoursinday;
  mids:startPx* exp sums 0.0005*-1+quoteCnt?2f;
  mids:0.01*floor 100*mids;
  bid:rnd mids-quoteCnt?0.03;
  ask:rnd mids+quoteCnt?0.03;
  bsize:`int$(600*1+quoteCnt?20);
  asize:`int$(600*1+quoteCnt?20);
  tradeIdx:til tradeCnt;
  quoteIdx:5*tradeIdx;
  side:tradeCnt?`buy`sell;
  price:0.01*floor 100*?[side=`buy; ask[quoteIdx]; bid[quoteIdx]];
  tsize:`int$((tradeCnt?1f)*?[side=`buy; asize[quoteIdx]; bsize[quoteIdx]]);
  .z.m.trades,:flip `time`sym`src`price`size!(ttimes;tradeCnt#sym;tradeCnt?`N`O`L;price;tsize);
  .z.m.quotes,:flip `time`sym`src`bid`ask`bsize`asize!(qtimes;quoteCnt#sym;quoteCnt?`N`O`L;bid;ask;bsize;asize);
  if[level=2;
  depthCnt:25*tradeCnt;
  dtimes:date+ `#asc startTime+depthCnt?hoursinday;
  dIdx:(til depthCnt) mod quoteCnt;
  dBid:bid[dIdx];dAsk:ask[dIdx];
  b1:`int$(600*1+depthCnt?20);b2:b1+`int$(600*1+depthCnt?5);b3:b1+`int$(600*1+depthCnt?10);b4:b1+`int$(600*1+depthCnt?15);b5:b1+`int$(600*1+depthCnt?20);
  a1:`int$(600*1+depthCnt?20);a2:a1+`int$(600*1+depthCnt?5);a3:a1+`int$(600*1+depthCnt?5);a4:a1+`int$(600*1+depthCnt?5);a5:a1+`int$(600*1+depthCnt?5);
  .z.m.depth,:flip `time`sym`bid1`bsize1`bid2`bsize2`bid3`bsize3`bid4`bsize4`bid5`bsize5`ask1`asize1`ask2`asize2`ask3`asize3`ask4`asize4`ask5`asize5!(dtimes;depthCnt#sym;dBid;b1;dBid-0.01;b2;dBid-0.02;b3;dBid-0.03;b4;dBid-0.04;b5;dAsk;a1;dAsk+0.01;a2;dAsk+0.02;a3;dAsk+0.03;a4;dAsk+0.04;a5);
  ];
  };

// function to generate the mock data for multiple syms on a given date
mockData:{[syms;date;startTime;endTime;rowCnts;startPxs;level]
  syms:$[11h=type syms; syms; enlist syms];
  rc:$[99h=type rowCnts; rowCnts; (enlist syms)!enlist rowCnts];
  spx:$[99h=type startPxs; startPxs; (enlist syms)!enlist startPxs];
  {[s;rc;spx;date;startTime;endTime;level] 
   sp:$[`sp in key .z.m; $[null .z.m.sp[s]; spx[s]; .z.m.sp[s]]; spx[s]];
   mockDataOne[s;date;startTime;endTime;rc[s];sp;level]}[;rc;spx;date;startTime;endTime;level] each syms;
   };

// function to generate mock data for multiple syms for the given date list
mockDataR:{[syms;datelist;startTime;endTime;rowCnts;startPxs;level]
  mockData[syms;datelist[0];startTime;endTime;rowCnts;startPxs;level];
  .z.m.sp:exec last price by sym from .z.m.trades; 
  {[syms;x;startTime;endTime;rowCnts;sp;level]
  .z.m.sp:exec last price by sym from .z.m.trades;
  mockData[syms;x;startTime;endTime;rowCnts;sp;2]}[syms;;startTime;endTime;rowCnts;sp;2]each 1_datelist;
  .z.m.sp::syms!(count syms)#0nf; 
  };

// function to write the data down to HDB for the given date list
mockHdb:{[dir;syms;dates;startTime;endTime;rowCnts;startPxs;level] 
  clearTables[]; 
  {[dir;syms;d;startTime;endTime;rowCnts;startPxs;level]
   mockData[syms;d;startTime;endTime;rowCnts;startPxs;level]; 
   .z.m.sp:syms!{last exec price from .z.m.trades where sym = x} each syms;
   `trades set .z.m.trades;
   `quotes set .z.m.quotes;
   `depth set .z.m.depth;
   .Q.hdpf[`:;dir;d;`sym]; clearTables[] }[dir;syms;;startTime;endTime;rowCnts;startPxs;level] each dates;
   .z.m.sp:syms!(count syms)#0nf;
  };
