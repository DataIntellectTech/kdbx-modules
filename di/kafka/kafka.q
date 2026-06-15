/ kafka consumer/producer interface - wraps kafkaq native library

/ default message handler - discards message silently
defaultkupd:{[k;x]};

/ default lib path derived from KDBLIB env var and os string
/ override with libpath config key if KDBLIB is not set in the environment
defaultlib:`$getenv[`KDBLIB],"/",string[.z.o],"/kafkaq";

/ ============================================================
/ module state and defaults
/ ============================================================

/ whether native library is loaded - overwritten by init
enabled:0b;

/ path to kafkaq library without file extension - overwritten by init
lib:defaultlib;

/ message handler called by C library on message receipt - overwritten by init
kupd:defaultkupd;

/ ============================================================
/ native function stubs - replaced by init when enabled:1b
/ ============================================================

/ initialise consumer with broker address and option dictionary
initconsumer:{[s;o]'"kafka not enabled"};

/ initialise producer with broker address and option dictionary
initproducer:{[s;o]'"kafka not enabled"};

/ disconnect and free consumer object and stop subscription thread
cleanupconsumer:{'"kafka not enabled"};

/ disconnect and free producer object
cleanupproducer:{'"kafka not enabled"};

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
  if[enabled;@[`.;`kupd;:;f]];
  };

init:{[config]
  / normalise config - handles (::) and ()!() identically
  cfg:$[99h=type config;config;()!()];
  .z.m.enabled:$[`enabled in key cfg;cfg`enabled;0b];
  .z.m.lib:$[`libpath in key cfg;cfg`libpath;defaultlib];
  .z.m.kupd:$[`kupd in key cfg;cfg`kupd;defaultkupd];
  if[enabled;
    libfile:hsym ` sv lib,$[.z.o like "w*";`dll;`so];
    if[()~key libfile;'"kafka lib not found: ",1_string libfile];
    .z.m.initconsumer:lib 2:(`initconsumer;2);
    .z.m.initproducer:lib 2:(`initproducer;2);
    .z.m.cleanupconsumer:lib 2:(`cleanupconsumer;1);
    .z.m.cleanupproducer:lib 2:(`cleanupproducer;1);
    .z.m.subscribe:lib 2:(`subscribe;2);
    .z.m.publish:lib 2:(`publish;4);
    / set global kupd - unavoidable side effect of native library design
    @[`.;`kupd;:;kupd];
    ];
  };
