/ kafka consumer/producer interface - wraps kafkaq native library

/ default message handler - routes message through injected logger
defaultkupd:{[k;x].z.m.loginfo[`kafka;"kupd: ","c"$x]};

/ default lib path derived from KDBLIB env var and os string
/ override with libpath config key if KDBLIB is not set in the environment
defaultlib:`$getenv[`KDBLIB],"/",string[.z.o],"/kafkaq";

/ ============================================================
/ module state and defaults
/ ============================================================

/ whether native library is loaded - overwritten by init; true by default on l64
enabled:.z.o in `l64;

/ path to kafkaq library without file extension - overwritten by init
lib:defaultlib;

/ message handler called by C library on message receipt - overwritten by init
kupd:defaultkupd;

/ ============================================================
/ native function stubs - replaced by init when enabled:1b and library loads
/ ============================================================

/ initialise consumer with broker address and option dictionary
initconsumer:{[s;o]'"kafka not enabled"};

/ initialise producer with broker address and option dictionary
initproducer:{[s;o]'"kafka not enabled"};

/ disconnect and free consumer object and stop subscription thread - rank-1 matches C lib 2:(`cleanupconsumer;1)
cleanupconsumer:{[x]'"kafka not enabled"};

/ disconnect and free producer object - rank-1 matches C lib 2:(`cleanupproducer;1)
cleanupproducer:{[x]'"kafka not enabled"};

/ start subscription thread for topic on partition - messages delivered to kupd
subscribe:{[t;p]'"kafka not enabled"};

/ publish byte vector to topic and partition with given key
publish:{[t;p;k;m]'"kafka not enabled"};

/ ============================================================
/ public api
/ ============================================================

setkupd:{[f]
  / update message handler; propagate to global kupd for C callback if enabled
  .z.m.kupd:f;
  if[.z.m.enabled;@[`.;`kupd;:;f]];
  };

init:{[config;deps]
  / config: dict with optional keys `enabled`libpath`kupd
  / deps: `log!(logdict)
  /   `log: `info`warn`error!(infofunc;warnfunc;errfunc) - required
  logdict:$[99h=type deps;$[(`log in key deps) and not (::)~deps`log;deps`log;()!()];()!()];
  if[not all `info`warn`error in key logdict;
    '"di.kafka: log dependency is required; pass `info`warn`error functions - see di.log or refer to confluence documentation";
    ];
  .z.m.loginfo:logdict`info;
  .z.m.logwarn:logdict`warn;
  .z.m.logerr:logdict`error;
  / normalise config - handles (::) and ()!() identically
  cfg:$[99h=type config;config;()!()];
  .z.m.enabled:$[`enabled in key cfg;cfg`enabled;.z.o in `l64];
  .z.m.lib:$[`libpath in key cfg;cfg`libpath;defaultlib];
  .z.m.kupd:$[`kupd in key cfg;cfg`kupd;defaultkupd];
  if[.z.m.enabled;
    libfile:hsym ` sv .z.m.lib,$[.z.o like "w*";`dll;`so];
    / protected key - kdbx throws on paths with non-existent ancestors
    libexists:@[{not ()~key x};libfile;{0b}];
    if[not libexists;
      .z.m.logerr[`kafka;"no such file ",1_string libfile]
      ];
    if[libexists;
      .z.m.initconsumer:.z.m.lib 2:(`initconsumer;2);
      .z.m.initproducer:.z.m.lib 2:(`initproducer;2);
      .z.m.cleanupconsumer:.z.m.lib 2:(`cleanupconsumer;1);
      .z.m.cleanupproducer:.z.m.lib 2:(`cleanupproducer;1);
      .z.m.subscribe:.z.m.lib 2:(`subscribe;2);
      .z.m.publish:.z.m.lib 2:(`publish;4);
      / set global kupd - unavoidable side effect of native library design
      @[`.;`kupd;:;.z.m.kupd];
      .z.m.loginfo[`kafka;"kupd is set to ",-3!.z.m.kupd];
      ];
    ];
  };
