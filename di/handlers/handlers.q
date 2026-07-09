/ central registry for KDB-X .z.* connection-lifecycle callbacks
/ the single sanctioned place to hook .z.* events - replaces per-file hand-rolled closure wrapping
/ observer events fan out to any number of registrants; decider events allow exactly one owner

/ module version - placeholder only; no project-wide version / di.depcheck convention exists yet
version:"0.1.0";

/ ============================================================
/ constants (load-time)
/ ============================================================

/ observer events - KDB-X discards the return value, so any number of side-effect-only handlers can coexist
observerevents:`.z.pc`.z.po`.z.exit`.z.wo`.z.wc;

/ decider events - KDB-X uses the return value as the outcome, so only one owner can coherently exist
/ .z.ph is deliberately absent - HTTP GET permissioning uses .h.val, not .z.*, and is out of scope (see register)
deciderevents:`.z.pg`.z.ps`.z.pi`.z.pp`.z.pw`.z.ws;

/ per-event observer registry template - keyed by handler name in registration order
registryschema:([name:`symbol$()] func:());

/ ============================================================
/ internal helpers
/ ============================================================

raiseerror:{[ctx;msg]
  / log the error under ctx then signal it, so failures are observable in the log and not just thrown
  .z.m.log[`error][ctx;msg];
  '"di.handlers: ",string[ctx],": ",msg;
  };

initstate:{
  / one-time setup of the empty registries - separated so re-init never wipes live state
  .z.m.registry:(`$())!();
  .z.m.original:(`$())!();
  .z.m.owner:(`$())!();
  };

runobserver:{[event;nm;func;arg]
  / apply one observer under protection - a throw is logged at warn and swallowed so the chain continues
  .[func;enlist arg;{[event;nm;e] .z.m.log[`warn][`handlers;"observer ",string[nm]," on ",(string event)," failed: ",e]}[event;nm]];
  };

runoriginal:{[event;arg]
  / apply the captured pre-existing handler last, isolated the same way as registered observers
  .[.z.m.original event;enlist arg;{[event;e] .z.m.log[`warn][`handlers;"original ",(string event)," handler failed: ",e]}[event]];
  };

dispatchobs:{[event;arg]
  / fan out to every registered observer in registration order, then run the captured original last, each isolated
  t:0!.z.m.registry event;
  runobserver[event;;;arg]'[t`name;t`func];
  runoriginal[event;arg];
  };

installobserver:{[event]
  / on first registration for an event, capture whatever is currently bound (KDB-X default if unset) and install the dispatcher
  .z.m.original[event]:@[value;event;{(::)}];
  .z.m.registry[event]:registryschema;
  set[event;dispatchobs[event;]];
  };

registerobserver:{[event;nm;func]
  / lazily install on first use, then add or replace this handler in registration order
  if[not event in key .z.m.original;installobserver event];
  .z.m.registry[event]:.z.m.registry[event] upsert (nm;func);
  .z.m.log[`info][`register;"registered observer ",string[nm]," on ",string event];
  };

registerdecider:{[event;nm;func]
  / single owner - a different name claiming an owned event is rejected; the same name reclaims (idempotent re-init)
  if[event in key .z.m.owner;
    if[not nm~.z.m.owner event;
      raiseerror[`register;(string event)," already owned by ",string[.z.m.owner event]," - call remove first"]]];
  set[event;func];
  .z.m.owner[event]:nm;
  .z.m.log[`info][`register;"registered decider ",string[nm]," on ",string event];
  };

removeobserver:{[event;nm]
  / drop the named handler; the dispatcher and captured original keep firing regardless of remaining count
  if[not event in key .z.m.registry;:(::)];
  .z.m.registry[event]:.z.m.registry[event] _ nm;
  .z.m.log[`info][`remove;"removed observer ",string[nm]," on ",string event];
  };

removedecider:{[event;nm]
  / relinquish ownership only if this name owns it, then restore the KDB-X built-in default via \x
  if[not event in key .z.m.owner;:(::)];
  if[not nm~.z.m.owner event;
    raiseerror[`remove;(string event)," is owned by ",string[.z.m.owner event],", not ",string nm]];
  system"x ",string event;
  .z.m.owner:.z.m.owner _ event;
  .z.m.log[`info][`remove;"removed decider ",string[nm]," on ",(string event),"; restored default"];
  };

/ ============================================================
/ public api
/ ============================================================

register:{[event;nm;func]
  / register a handler for a .z.* event - fan-out for observers, single-owner for deciders
  if[not -11h=type event;raiseerror[`register;"event must be a symbol"]];
  if[not -11h=type nm;raiseerror[`register;"name must be a symbol"]];
  if[not (type func) within 100 112h;raiseerror[`register;"func must be a function"]];
  if[event~`.z.ph;
    raiseerror[`register;".z.ph is not managed by di.handlers - HTTP GET permissioning uses .h.val, not .z.*"]];
  $[event in observerevents; registerobserver[event;nm;func];
    event in deciderevents;  registerdecider[event;nm;func];
    raiseerror[`register;"unsupported event ",string event]];
  };

remove:{[event;nm]
  / remove a handler - observers drop from the fan-out, deciders relinquish ownership and restore the KDB-X default
  if[not -11h=type event;raiseerror[`remove;"event must be a symbol"]];
  if[not -11h=type nm;raiseerror[`remove;"name must be a symbol"]];
  $[event in observerevents; removeobserver[event;nm];
    event in deciderevents;  removedecider[event;nm];
    raiseerror[`remove;"unsupported event ",string event]];
  };

list:{[event]
  / return the registered handlers for a single event - observers as a name/func table, deciders as their owner
  if[not -11h=type event;raiseerror[`list;"event must be a symbol"]];
  :$[event in observerevents; $[event in key .z.m.registry;0!.z.m.registry event;0!registryschema];
     event in deciderevents;  $[event in key .z.m.owner;([]name:enlist .z.m.owner event);([]name:`symbol$())];
     raiseerror[`list;"unsupported event ",string event]];
  };

init:{[deps]
  / initialise di.handlers - validate the required log dependency and set up empty registries (idempotent)
  / deps: a dict with a `log key; log must be a dict of binary {[c;m]} functions with `info`warn`error keys
  / example: handlers.init[enlist[`log]!enlist logdep]
  if[99h<>type deps;
    '"di.handlers: deps must be a dict with `log key"];
  if[not `log in key deps;
    '"di.handlers: log dependency is required; pass `info`warn`error functions keyed on `log"];
  if[99h<>type deps`log;
    '"di.handlers: log value must be a dict; pass `info`warn`error functions"];
  if[not all `info`warn`error in key deps`log;
    '"di.handlers: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  .z.m.log:deps`log;
  / initialise the registries only on first init - a direct (module-rewritten) reference detects prior setup
  if[not @[{.z.m.registry;1b};::;0b];initstate[]];
  .z.m.log[`info][`init;"di.handlers initialised"];
  };
