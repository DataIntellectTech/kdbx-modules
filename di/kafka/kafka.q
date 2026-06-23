/ kafka - wrapper around the kafkaq native library
/ provides consumer and producer lifecycle management plus a configurable message callback
/ the native library calls .kupd in the root namespace on message receipt; init sets a forwarder
/ into .z.m.kupd so the callback can be replaced at runtime via setkupd without re-initialising
/ the log dependency is required - init errors immediately if absent or malformed
/ log functions are monadic {[msg]} loggers; a kx.log instance satisfies the contract

/ default message callback - prints message bytes as chars to stdout
/ safe to use stdout here: kupd can only fire after initconsumer+subscribe, both require init
/ override via setkupd or by passing kupd in the config dict to init
defaultkupd:{[k;x] -1 `char$x;};

/ configuration defaults
kupd:defaultkupd;
enabled:.z.o in `l64;

/ ============================================================
/ native function stubs - replaced by bindfunctions when library loads
/ ============================================================

initconsumer:{[s;o]'"di.kafka: kafka not initialised - call init first"};
initproducer:{[s;o]'"di.kafka: kafka not initialised - call init first"};
cleanupconsumer:{[h]'"di.kafka: kafka not initialised - call init first"};
cleanupproducer:{[h]'"di.kafka: kafka not initialised - call init first"};
subscribe:{[t;p]'"di.kafka: kafka not initialised - call init first"};
publish:{[t;p;k;m]'"di.kafka: kafka not initialised - call init first"};

/ ============================================================
/ internal functions
/ ============================================================

setdeps:{[deps]
  / accept a bare kx.log instance (info/warn/error at top level) or a full deps dict keyed on `log
  d:$[(99h=type deps)and not `log in key deps;enlist[`log]!enlist deps;deps];
  logval:$[99h=type d;$[`log in key d;d`log;(::)];(::)];
  if[not $[99h=type logval;all `info`warn`error in key logval;0b];
    '"di.kafka: log dep required - pass a kx.log instance or `info`warn`error!(infofn;warnfn;errfn) keyed on `log"];
  .z.m.log:logval;
  };

setconfig:{[config]
  / apply recognised configuration overrides on top of current defaults; returns normalised cfg dict
  cfg:$[99h=type config;config;()!()];
  if[`enabled in key cfg; .z.m.enabled:cfg`enabled];
  if[`libpath in key cfg; .z.m.lib:cfg`libpath];
  if[`kupd in key cfg; .z.m.kupd:cfg`kupd];
  cfg
  };

loadlib:{[libpath]
  / resolve and load the native kafkaq shared library from the configured path
  / the os-appropriate extension (.so or .dll) is appended automatically
  lib:`$string[libpath],"/",string[.z.o],"/kafkaq";
  libfile:hsym ` sv lib,$[.z.o like "w*";`dll;`so];
  libexists:@[{not ()~key x};libfile;{0b}];
  if[not libexists;
    .z.m.log[`error]["kafka: native library not found at ",string libfile];
    '"di.kafka: native library not found at ",string libfile];
  .z.m.log[`info]["kafka: loading library ",string libfile];
  .z.m.lib:lib;
  };

bindfunctions:{[]
  / bind the six c functions from the loaded kafkaq library into module-local state
  / overwrites the stubs defined at module level
  .z.m.initconsumer:.z.m.lib 2:(`initconsumer;2);
  .z.m.initproducer:.z.m.lib 2:(`initproducer;2);
  .z.m.cleanupconsumer:.z.m.lib 2:(`cleanupconsumer;1);
  .z.m.cleanupproducer:.z.m.lib 2:(`cleanupproducer;1);
  .z.m.subscribe:.z.m.lib 2:(`subscribe;2);
  .z.m.publish:.z.m.lib 2:(`publish;4);
  };

/ ============================================================
/ public api
/ ============================================================

setkupd:{[f]
  / replace the message callback invoked when a subscribed message arrives
  / f must be a binary function {[k;x]} where k is the message key (symbol) and x is the payload (bytes)
  / the root .kupd forwarder always delegates to the current value - swap takes effect immediately
  / note: messages in-flight from the c background thread may briefly invoke the previous handler
  .z.m.kupd:f;
  };

init:{[config;deps]
  / initialise the kafka module - validate deps, apply config, load native library
  / config: required dict with `libpath (root library directory - os subdirectory is appended automatically)
  /         optionally `kupd to set a custom message callback
  / deps:   kx.log instance (passed directly) or dict with `log -> `info`warn`error!(infofn;warnfn;errfn)
  / example:
  /   kafka.init[enlist[`libpath]!enlist`$/opt/kdb/lib;kxlog.createLog[]]
  setdeps deps;
  cfg:setconfig config;
  if[enabled;
    if[not `libpath in key cfg;
      '"di.kafka: config must contain `libpath - root library directory containing the os-specific kafkaq build"];
    loadlib cfg`libpath;
    bindfunctions[];
    / install the root .kupd forwarder so the native library delegates to our configurable callback
    `.kupd set {[k;x] .z.m.kupd[k;x]};
    ];
  .z.m.log[$[enabled;`info;`warn]]["kafka: di.kafka initialised",$[enabled;"";" (native library not loaded - platform not supported)"]];
  };
