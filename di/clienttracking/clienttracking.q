/ track the client sessions connected to a KDB-X process in a session table
/ consumes di.handlers (injected) to observe connection open/close and, once a query owner
/ exists, to count per-request usage - it never assigns .z.* directly

/ module version - the exported semver di.depcheck reads to satisfy other modules' declared minimums
version:"0.1.0";

/ ============================================================
/ constants (load-time)
/ ============================================================

/ session table schema - one row per client session; an open session has a null endp
/ w is grouped for fast per-handle lookup; hits/sz are longs
clientschema:([]
  w:`g#`int$();          / connection handle (.z.w at open)
  ipa:`symbol$();        / client ip address, dotted-decimal
  u:`symbol$();          / client user (.z.u at open)
  a:`int$();             / client ip address, raw int (.z.a at open)
  startp:`timestamp$();  / session start - connection open time
  endp:`timestamp$();    / session end - connection close time; null while open
  lastp:`timestamp$();   / time of the last request seen from this client
  hits:`long$();         / number of requests served for this client
  sz:`long$());          / total (approximate) bytes of results returned to this client

/ priority used when registering with di.handlers - lower runs first; 0 is a neutral default
handlerpriority:0;

/ idle/retention defaults, overridable via init config
defaultmaxidle:0D00:15:00;  / force-close a live handle idle for longer than this (0D disables)
defaultretain:0D00:05:00;   / purge a closed session this long after it ended

/ the phased query events usage counting attaches to (as post-phase watchers)
usageevents:`.z.pg`.z.ps`.z.ws;

/ ============================================================
/ internal helpers
/ ============================================================

ipa:{[a]
  / format a raw .z.a int ip address as a dotted-decimal symbol
  / .z.a is a signed int32 (high ips are negative); 0x0 vs takes its two's-complement bytes and
  / "i"$ casts each byte UNSIGNED (0-255), so octets >= 128 render correctly (e.g. 192.168.0.1)
  :`$"." sv string "i"$0x0 vs a;
  };

raiseerror:{[ctx;msg]
  / internal - log an error under ctx then signal it, so failures are observable as well as thrown
  .z.m.logerr[ctx;msg];
  '"di.clienttracking: ",string[ctx],": ",msg;
  };

track:{[h]
  / record a newly-seen client handle - sweep first, then append an open session row for h
  cleanup[];
  .z.m.clients:.z.m.clients upsert (h;ipa .z.a;.z.u;.z.a;.z.p;0Np;.z.p;0j;0j);
  };

closeclient:{[h]
  / mark the open session for handle h as closed, then sweep
  .z.m.clients:update endp:.z.p from .z.m.clients where w=h,null endp;
  cleanup[];
  };

hitpost:{[result;args]
  / usage post-handler - di.handlers calls post[result;args], so this must be binary; args is unused
  / bumps the request count and result-byte total for the calling client (.z.w)
  / runs only on a successful exec (di.handlers post fires after the owner returns), so it cannot
  / see errors; on a multithreaded (negative \p) process a global write here hits 'noupdate and is
  / isolated/logged by di.handlers rather than counting
  .z.m.clients:update lastp:.z.p,hits:hits+1,sz:sz+-22!result from .z.m.clients where w=.z.w,null endp;
  };

disableusage:{[]
  / remove any usage post-handlers this module registered (idempotent - di.handlers no-ops an unknown name)
  .z.m.handlers[`remove][;`post;`clienttracking] each usageevents;
  };

registerlifecycle:{[]
  / register the connection and websocket open/close observers (idempotent - di.handlers replaces in place)
  .z.m.handlers[`register][`.z.po;`;`clienttracking;handlerpriority;track];
  .z.m.handlers[`register][`.z.pc;`;`clienttracking;handlerpriority;closeclient];
  .z.m.handlers[`register][`.z.wo;`;`clienttracking;handlerpriority;track];
  .z.m.handlers[`register][`.z.wc;`;`clienttracking;handlerpriority;closeclient];
  };

/ ============================================================
/ public api
/ ============================================================

init:{[deps]
  / wire the required dependencies (log, handlers) and optional config, then register the lifecycle handlers
  / deps: a dict with `log (info/warn/error binary {[c;m]} funcs) and `handlers (di.handlers register/remove/list)
  /   optional: `maxidle (timespan), `retain (timespan), `trackusage (boolean, default 1b)
  / example: ct.init[`log`handlers!(logdep;hdep)]
  if[99h<>type deps;
    '"di.clienttracking: deps must be a dict with `log and `handlers keys"];
  if[not `log in key deps;
    '"di.clienttracking: log dependency is required; pass `info`warn`error functions keyed on `log"];
  if[99h<>type deps`log;
    '"di.clienttracking: log value must be a dict; pass `info`warn`error functions"];
  if[not all `info`warn`error in key deps`log;
    '"di.clienttracking: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  if[not `handlers in key deps;
    '"di.clienttracking: handlers dependency is required; pass di.handlers register/remove/list keyed on `handlers"];
  if[99h<>type deps`handlers;
    '"di.clienttracking: handlers value must be a dict; pass register/remove/list functions"];
  if[not all `register`remove`list in key deps`handlers;
    '"di.clienttracking: handlers dict must have `register`remove`list keys; got: ",(", " sv string key deps`handlers)];
  / optional config - validate types up front (nested if, not `and`, to avoid eager-eval on an absent key)
  if[`maxidle in key deps;
    if[not -16h=type deps`maxidle;'"di.clienttracking: maxidle must be a timespan"]];
  if[`retain in key deps;
    if[not -16h=type deps`retain;'"di.clienttracking: retain must be a timespan"]];
  if[`trackusage in key deps;
    if[not -1h=type deps`trackusage;'"di.clienttracking: trackusage must be a boolean"]];
  .z.m.loginfo:(deps`log)`info;
  .z.m.logwarn:(deps`log)`warn;
  .z.m.logerr:(deps`log)`error;
  .z.m.handlers:deps`handlers;
  .z.m.maxidle:$[`maxidle in key deps;deps`maxidle;defaultmaxidle];
  .z.m.retain:$[`retain in key deps;deps`retain;defaultretain];
  .z.m.trackusage:$[`trackusage in key deps;deps`trackusage;1b];
  / create the session table on first init only; a re-init must leave the existing table intact
  if[not `clients in key .z.m;.z.m.clients:clientschema];
  registerlifecycle[];
  $[.z.m.trackusage;enableusage[];disableusage[]];
  .z.m.loginfo[`init;"di.clienttracking initialised"];
  };

getclients:{[]
  / the current client-session tracking table - one row per session (open rows have a null endp)
  :.z.m.clients;
  };

addclient:{[h]
  / manually record a client handle in the tracking table using the current .z context (like TorQ's addw)
  if[not -6h=type h;raiseerror[`addclient;"handle must be an int"]];
  track h;
  };

cleanup:{[]
  / reap sessions whose handle has gone, force-close idle live handles, purge expired closed rows
  / runs automatically on every open/close; also exported so a host can drive it periodically (di.timer)
  now:.z.p;
  .z.m.clients:update endp:now from .z.m.clients where null endp,not w in key .z.W;
  if[0D<.z.m.maxidle;
    idle:exec w from .z.m.clients where null endp,w in key .z.W,lastp<now-.z.m.maxidle;
    if[count idle;
      @[hclose;;::] each idle;
      .z.m.clients:update endp:now from .z.m.clients where w in idle,null endp];
    ];
  .z.m.clients:delete from .z.m.clients where not null endp,endp<now-.z.m.retain;
  };

enableusage:{[]
  / (re)wire usage counting onto each phased query event that now has an exec owner; idempotent
  / call again after the query owner (gateway/permissions) is registered, since post cannot attach before exec
  {[event]
    owned:`exec in exec phase from .z.m.handlers[`list] event;
    if[owned;
      .z.m.handlers[`register][event;`post;`clienttracking;handlerpriority;hitpost];
      .z.m.loginfo[`enableusage;"usage counting active on ",string event]];
    if[not owned;
      .z.m.logwarn[`enableusage;"usage counting on ",string[event]," deferred: no exec owner yet"]];
    } each usageevents;
  };

getapimeta:{[]
  / this module's api metadata, one row per CALLABLE api function (NOT init/getapimeta/version - those are
  / plumbing/metadata di.torq handles by convention), for di.torq to collect and register with di.api.
  / names are bare; di.torq applies process-wide qualification. one (name;public;descrip;params;return) row per line
  :flip `name`public`descrip`params`return!flip(
    (`getclients; 1b; "current client-session tracking table (open and recently-closed sessions)"; "[]"; "table: one row per client session");
    (`addclient;  1b; "manually record a client handle in the tracking table";                     "[int: handle]"; "null");
    (`cleanup;    1b; "run a cleanup sweep - reap gone handles, close idle handles, purge expired"; "[]"; "null");
    (`enableusage;1b; "(re)wire usage counting onto phased query events that now have an exec owner"; "[]"; "null"));
  };
