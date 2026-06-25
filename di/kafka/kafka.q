/ kafka - wrapper around the kafkaq native library
/ provides consumer and producer lifecycle management plus a configurable message callback
/ the native library calls .kupd in the root namespace on message receipt; init sets a forwarder
/ into .z.m.kupd so the callback can be replaced at runtime via setkupd without re-initialising
/ the log dependency is required - init errors immediately if absent or malformed
/ log functions are binary {[c;m]} where c is a symbol context and m is a string

/ default message callback - no-op; replace with setkupd after init
defaultkupd:{[k;x] (::)};

/ configuration defaults
kupd:defaultkupd;
enabled:.z.o in `l64;

/ ============================================================
/ native function internals - stubs replaced by bindfunctions when library loads
/ exported forwarders delegate to these by bare name so bindfunctions updates are reflected immediately
/ ============================================================

nativeinitconsumer:{[s;o]'"di.kafka: kafka not initialised - call init first"};
nativeinitproducer:{[s;o]'"di.kafka: kafka not initialised - call init first"};
nativecleanupconsumer:{'"di.kafka: kafka not initialised - call init first"};
nativecleanupproducer:{'"di.kafka: kafka not initialised - call init first"};
nativesubscribe:{[t;p]'"di.kafka: kafka not initialised - call init first"};
nativepublish:{[t;p;k;m]'"di.kafka: kafka not initialised - call init first"};

/ exported forwarders - captured at use time, delegate to native* internals dynamically
initconsumer:{[s;o] nativeinitconsumer[s;o]};
initproducer:{[s;o] nativeinitproducer[s;o]};
cleanupconsumer:{nativecleanupconsumer[]};
cleanupproducer:{nativecleanupproducer[]};
subscribe:{[t;p] nativesubscribe[t;p]};
publish:{[t;p;k;m] nativepublish[t;p;k;m]};

/ ============================================================
/ internal helpers
/ ============================================================

normlog:{[logdict]
  / detect kx.log instance by presence of kx.log-specific keys (getlvl, sinks, fmts)
  / kx.log functions are monadic - wrap each into binary {[c;m]} and embed context in the message
  / plain {[c;m]} log dicts (info`warn`error only) pass through unchanged
  $[any `getlvl`sinks`fmts in key logdict;
    `info`warn`error!(
      {[fn;c;m] fn[string[c],": ",m]}[logdict`info;];
      {[fn;c;m] fn[string[c],": ",m]}[logdict`warn;];
      {[fn;c;m] fn[string[c],": ",m]}[logdict`error;]);
    logdict]
  };

setconfig:{[deps]
  / apply recognised configuration overrides; dep keys (log etc.) are ignored
  cfg:$[99h=type deps;deps;()!()];
  if[`enabled in key cfg; .z.m.enabled:cfg`enabled];
  if[`kupd in key cfg; .z.m.kupd:cfg`kupd];
  };

loadlib:{[libpath]
  / resolve and validate the native kafkaq shared library path - actual binding happens in bindfunctions
  / the os-appropriate extension (.so or .dll) is appended automatically
  lib:`$string[libpath],"/",string[.z.o],"/kafkaq";
  libfile:hsym ` sv lib,$[.z.o like "w*";`dll;`so];
  libexists:@[{not ()~key x};libfile;{0b}];
  if[not libexists;
    .z.m.log[`error][`kafka;"native library not found at ",string libfile];
    '"di.kafka: native library not found at ",string libfile];
  .z.m.log[`info][`kafka;"library found at ",string libfile];
  .z.m.lib:lib;
  };

bindfunctions:{[]
  / bind the six c functions from the loaded kafkaq library into the native* internal targets
  / the exported forwarders (initconsumer etc.) delegate to these by bare name, so updates here
  / are immediately reflected in all subsequent calls through the exported api
  / rawcleanupconsumer and rawcleanupproducer are unary in the c interface - wrapped as niladic
  .z.m.nativeinitconsumer:.z.m.lib 2:(`initconsumer;2);
  .z.m.nativeinitproducer:.z.m.lib 2:(`initproducer;2);
  .z.m.rawcleanupconsumer:.z.m.lib 2:(`cleanupconsumer;1);
  .z.m.rawcleanupproducer:.z.m.lib 2:(`cleanupproducer;1);
  .z.m.nativecleanupconsumer:{rawcleanupconsumer[(::)]};
  .z.m.nativecleanupproducer:{rawcleanupproducer[(::)]};
  .z.m.nativesubscribe:.z.m.lib 2:(`subscribe;2);
  .z.m.nativepublish:.z.m.lib 2:(`publish;4);
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

init:{[deps]
  / initialise the kafka module - validate deps, apply config, load native library
  / deps: dict containing `log (required) plus optional `libpath, `enabled, `kupd
  / log dep: `info`warn`error!({[c;m]};{[c;m]};{[c;m]}) - binary, c=context symbol, m=string
  / examples:
  /   kafka.init[`log`libpath!(logdep;`$/opt/kdb/lib)]
  /   kafka.init[`log`libpath`enabled!(logdep;`$/opt/kdb/lib;0b)]
  if[99h<>type deps;
    '"di.kafka: deps must be a dict with `log key"];
  if[not `log in key deps;
    '"di.kafka: log dependency is required; pass `info`warn`error!(infofn;warnfn;errfn) keyed on `log"];
  if[99h<>type deps`log;
    '"di.kafka: log value must be a dict; pass `info`warn`error functions"];
  if[not all `info`warn`error in key deps`log;
    '"di.kafka: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  .z.m.log:normlog deps`log;
  setconfig deps;
  if[enabled;
    if[not `libpath in key deps;
      '"di.kafka: deps must contain `libpath - root library directory containing the os-specific kafkaq build"];
    loadlib deps`libpath;
    bindfunctions[];
    `.kupd set {[k;x] .z.m.kupd[k;x]};
  ];
  .z.m.log[$[enabled;`info;`warn]][`kafka;"di.kafka initialised",$[enabled;"";" (native library not loaded - platform not supported)"]];
  };
