\d .sctp

chainedtp:@[value;`chainedtp;0b];                    / switches between STP and SCTP
loggingmode:@[value;`loggingmode;`none];             / [none|create|parent]
tickerplantname:@[value;`tickerplantname;`stp1];
tpconnsleep:@[value;`tpconnsleep;10];
tpcheckcycles:@[value;`tpcheckcycles;0W];
subscribeto:@[value;`subscribeto;`];
subscribesyms:@[value;`subscribesyms;`];
replay:@[value;`replay;0b];
schema:@[value;`schema;1b];

/ subscribe to segmented tickerplant
subscribe:{[]
  s:.sub.getsubscriptionhandles[`;tickerplantname;()!()];
  if[count s;
      subproc:first s;
      `.sctp.tph set subproc`w;
      .z.m.log[`info][`subscribe;"subscribing to ", string subproc`procname];
      r:.sub.subscribe[subscribeto;subscribesyms;schema;replay;subproc];
      if[`d in key r;.u.d::r[`d]];
      if[(`icounts in key r) & (loggingmode<>`create);
        subtabs:$[subscribeto~`;key r`icounts;subscribeto],();
        .u.jcounts::.u.icounts::$[0=count r`icounts;()!();subtabs!enlist [r`icounts]subtabs];
      ]
    ];
  }

/ initialise chained STP
init:{
  (use`di.subscriptions)[`init][.z.m.params;.z.m.deps];
  `endofperiod set {[x;y;z] .stplg.endofperiod[x;y;z]};
  `endofday set {[x;y] .stplg.endofday[x;y]};
  .servers.startupdepnamecycles[.sctp.tickerplantname;.sctp.tpconnsleep;.sctp.tpcheckcycles];
  .sctp.subscribe[];
 };

\d .

/ extract data from incoming table as a list
upd:{[t;x]
  x:value flip x;
  .u.upd[t;x]
 }
