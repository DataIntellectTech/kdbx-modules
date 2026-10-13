.sctp.chainedtp:@[value;`.sctp.chainedtp;0b];                    / switches between STP and SCTP
.sctp.loggingmode:@[value;`.sctp.loggingmode;`none];             / [none|create|parent]
.sctp.tickerplantname:@[value;`.sctp.tickerplantname;`stp1];
.sctp.tpconnsleep:@[value;`.sctp.tpconnsleep;10];
.sctp.tpcheckcycles:@[value;`.sctp.tpcheckcycles;0W];
.sctp.subscribeto:@[value;`.sctp.subscribeto;`];
.sctp.subscribesyms:@[value;`.sctp.subscribesyms;`];
.sctp.replay:@[value;`.sctp.replay;0b];
.sctp.schema:@[value;`.sctp.schema;1b];

/ subscribe to segmented tickerplant
.sctp.subscribe:{[]
  s:.sub.getsubscriptionhandles[`;.sctp.tickerplantname;()!()];
  if[count s;
      subproc:first s;
      `.sctp.tph set subproc`w;
      .z.m.log[`info][`subscribe;"subscribing to ", string subproc`procname];
      r:.sub.subscribe[.sctp.subscribeto;.sctp.subscribesyms;.sctp.schema;.sctp.replay;subproc];
      if[`d in key r;.u.d::r[`d]];
      if[(`icounts in key r) & (.sctp.loggingmode<>`create);
        subtabs:$[.sctp.subscribeto~`;key r`icounts;.sctp.subscribeto],();
        .u.jcounts::.u.icounts::$[0=count r`icounts;()!();subtabs!enlist [r`icounts]subtabs];
      ]
    ];
  }

/ initialise chained STP
.sctp.init:{
  `endofperiod set {[x;y;z] .stplg.endofperiod[x;y;z]};
  `endofday set {[x;y] .stplg.endofday[x;y]};
  .servers.startupdepnamecycles[.sctp.tickerplantname;.sctp.tpconnsleep;.sctp.tpcheckcycles];
  .sctp.subscribe[];
 };

/ extract data from incoming table as a list
@[`.;`upd;:;{[t;x]
  x:value flip x;
  .u.upd[t;x]
 }];
