/ upd and zts wrapper functions

/ check for end of day/period and call inner upd
.stpps.upd.def:{[t;x]
  if[.stplg.nextendUTC<now:.z.p;.stplg.checkends now];
  / type check allows update messages to contain multiple tables/data
  $[0h<type t;.stplg.updmsg'[t;x;now+.z.m.eod.getdailyadj[]];.stplg.updmsg[t;x;now+.z.m.eod.getdailyadj[]]];
  .stplg.seqnum+:1;
 };

/ chained: no period/day end check
.stpps.upd.chained:{[t;x]
  now:.z.p;
  $[0h<type t;.stplg.updmsg'[t;x;now+.z.m.eod.getdailyadj[]];.stplg.updmsg[t;x;now+.z.m.eod.getdailyadj[]]];
  .stplg.seqnum+:1;
 };

/ call inner zts and check for end of day/period
.stpps.zts.def:{
  .stplg.ts now:.z.p;
  .stplg.checkends now
 };

/ chained: no period/day end check
.stpps.zts.chained:{
  .stplg.ts now:.z.p
 };
