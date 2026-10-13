/ di.torq.proc.segmentedtp - segmented tickerplant

/ a symbol, a string or a list of strings (TOML has no symbol type)
tosym:{[x] $[type[x] in 0 10 -10h;`$x;x]};

init:{[config;deps]
  if[not `log in key deps;'"di.torq.proc.segmentedtp: log dependency is required - see di.util.log"];
  if[not `timer in key deps;'"di.torq.proc.segmentedtp: timer dependency is required - see di.timer"];
  if[not `handlers in key deps;'"di.torq.proc.segmentedtp: handlers dependency is required - see di.torq.handlers"];
  .z.m.log:deps`log;
  .z.m.procname:config`procname;
  .z.m.proctype:config`proctype;
  .z.m.params:config;
  (use`di.subscriptions)[`init][config;deps];
  (use`di.pubsub)[`init][enlist[`log]!enlist deps`log];
  r:deps[`handlers]`register;
  r[`.z.pc;`;`stpps;0j;.stpps.closesub];
  .z.m.eod:use`di.eodtime;
  .z.m.eod.init[(enlist[`log]!enlist deps`log),$[`eodtime in key config;config`eodtime;()!()]];
  if[`stplg_kdbtplog in key config;.stplg.kdbtplog:tosym config`stplg_kdbtplog];
  .stplg.multilog:$[`stplg_multilog in key config;tosym config`stplg_multilog;`tabperiod];
  .stplg.multilogperiod:$[`stplg_multilogperiod in key config;config`stplg_multilogperiod;0D01];
  .stplg.errmode:$[`stplg_errmode in key config;config`stplg_errmode;1b];
  .stplg.batchmode:$[`stplg_batchmode in key config;tosym config`stplg_batchmode;`defaultbatch];
  .stplg.replayperiod:$[`stplg_replayperiod in key config;tosym config`stplg_replayperiod;`day];
  .stplg.customcsv:$[`stplg_customcsv in key config;tosym config`stplg_customcsv;`];
  .stplg.errorlogname:$[`stplg_errorlogname in key config;tosym config`stplg_errorlogname;`segmentederrorlogfile];
  .sctp.chainedtp:$[`sctp_chainedtp in key config;config`sctp_chainedtp;0b];
  .sctp.loggingmode:$[`sctp_loggingmode in key config;tosym config`sctp_loggingmode;`none];
  .sctp.tickerplantname:$[`sctp_tickerplantname in key config;tosym config`sctp_tickerplantname;`stp1];
  .sctp.tpconnsleep:$[`sctp_tpconnsleep in key config;config`sctp_tpconnsleep;10];
  .sctp.tpcheckcycles:$[`sctp_tpcheckcycles in key config;config`sctp_tpcheckcycles;0W];
  .sctp.subscribeto:$[`sctp_subscribeto in key config;tosym config`sctp_subscribeto;`];
  .sctp.subscribesyms:$[`sctp_subscribesyms in key config;tosym config`sctp_subscribesyms;`];
  .sctp.replay:$[`sctp_replay in key config;config`sctp_replay;0b];
  .sctp.schema:$[`sctp_schema in key config;config`sctp_schema;1b];
  if[`createlogs in key config;set[`createlogs;config`createlogs]];
  / subscribers replay from the parent's logs
  if[.sctp.loggingmode=`parent;.stplg.replaylog:{[t] .sctp.tph (`.stplg.replaylog; t)}];
  / singular or tabular: no intraday roll
  if[.stplg.multilog in `singular`tabular;.stplg.multilogperiod:1D];
  / custom: logging mode per table
  if[.stplg.multilog~`custom;
    @[{.stplg.custommode:1_(!) . ("SS";",")0: x};.stplg.customcsv;{.z.m.log[`error][`stp;"failed to load custom mode csv"]}]];
  / die if the main STP dies
  r[`.z.pc;`;`sctp;0j;{[x] if[.sctp.chainedtp;if[.sctp.tph=x;.z.m.log[`error][`.z.pc;"lost connection to tickerplant : ",string .sctp.tickerplantname];exit 1]]}];
  / close logs on clean exit
  r[`.z.exit;`;`stplg;0j;{[x]
    if[not x~0i;.z.m.log[`error][`stpexit;"Bad exit!"];:()];
    .z.m.log[`info][`stpexit;"Exiting process"];
    if[.stplg.batchmode=`memorybatch;
      .z.m.log[`info][`stpexit;"STP shutdown unexpectedly, batchmode = `memorybatch, therefore flushing any remaining data to the on-disk log file"];
      .stplg.zts.memorybatch[];
      .z.m.log[`info][`stpexit;"Complete!"]];
    if[.sctp.chainedtp and not .sctp.loggingmode=`create;:()];
    .z.m.log[`info][`stpexit;"Closing off log files"];
    .stpm.updmeta[.stplg.multilog][`close;.stpps.t;.z.p];
    .stplg.closelog each .stpps.t}];
  (`..setup)[.stplg.batchmode];
  / chained: subscribe to the main STP; otherwise load the schema file
  $[.sctp.chainedtp;.sctp.init[];(`..loadschemas)[]];
  (`..generateschemas)[];
  / again after di.torq's .ps.initialise, which registers every root table
  if[`addinitlist in key `.proc;.proc.addinitlist(`generateschemas;`)];
  .stplg.init[string .z.m.procname];
  }

/ allow tickerplant to create a log file
@[`.;`createlogs;:;@[value;`createlogs;1b]];

/ subscribers use this to determine what type of process they are talking to
@[`.;`tptype;:;`segmented];

@[`.;`tablelist;:;{.stpps.t}];

/ subscribers who want to replay need this info
@[`.;`subdetails;:;{[tabs;instruments]
 `schemalist`logfilelist`rowcounts`date`logdir!(.ps.subscribe\:[tabs;instruments];.stplg.replaylog[tabs];tabs#.stplg `rowcount;.z.m.eod.getd[];.stplg.kdbtplog)
 }];

/ table and schema information and default table upd functions
@[`.;`generateschemas;:;{
  .stpps.init[tables[] except `currlog`heartbeat`logmsg`svrstoload];
  .stpps.attrstrip[.stpps.t];
  / table upd functions attach the current timestamp; chained they do nothing
  $[.sctp.chainedtp;
    .stplg.updtab:(.stpps.t!(count .stpps.t)#{[x;y] x}),.stplg.updtab;
    .stplg.updtab:(.stpps.t!(count .stpps.t)#{(enlist(count first x)#y),x}),.stplg.updtab
    ]
  }];

/ load in schema file and kill proc if not present
@[`.;`loadschemas;:;{
  if[not `schemafile in key .z.m.params;.z.m.log[`error][`loadschema;"Schema file required!"];exit 1];
  @[{system"l ",x};raze .z.m.params[`schemafile];{.z.m.log[`error][`loadschema;"Failed to load schema file!"];exit 1}];
 }];

/ upd and zts behaviour from the batch mode
@[`.;`setup;:;{[batch]
  if[not all batch in/: key'[.stplg`upd`zts];'"mode ",(string batch)," must be defined in both .stplg.upd and .stplg.zts"];
  chainmode:$[.sctp.chainedtp;`chained;`def];
  .stplg.updmsg:.stplg.upd[batch];
  .stplg.ts:.stplg.zts[batch];
  .u.upd:.stpps.upd[chainmode];
  set[`.z.ts;{[f;x] @[;x;()]each f}(@[value;`.z.ts;{{}}];.stpps.zts[chainmode])];
  / error mode: failed updates go to a separate log
  if[.stplg.errmode;
    .stp.upd:.u.upd;
    .u.upd:{[t;x] .[.stp.upd;(t;x);{.stplg.badmsg[x;y;z]}[;t;x]]}
   ];
  if[not system "t";.z.m.log[`info][`timer;"defaulting timer to 1000ms"];system"t 1000"];
 }];
