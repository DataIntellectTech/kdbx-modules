/ central registry for KDB-X .z.* connection-lifecycle callbacks
/ the single sanctioned place to hook .z.* events - replaces per-file hand-rolled closure wrapping
/ simple events fan out to any number of registrants; phased events thread pre -> exec -> transform -> post around one owner

/ version is read from the VERSION file (init.q); di.depcheck reads that file for the manifest graph
/ NOTE: `transform` phase (chained result rewrite between exec and post) is a TorqX addition on top
/ of the upstream feature-handlers design - see docs/reconciliation/handlers.md. Fed back to that PR.

/ ============================================================
/ constants (load-time)
/ ============================================================

/ simple events - KDB-X discards the return value, so any number of side-effect-only handlers can coexist (phase must be `)
observerevents:`.z.pc`.z.po`.z.exit`.z.wo`.z.wc;

/ phased events - pre (transform request) -> exec (single owner) -> transform (rewrite result) -> post (observe)
/ .z.pw is included but binary and pre-less (see register); .z.ph replaces the built-in HTTP GET handler wholesale (see notes)
phasedevents:`.z.pg`.z.ps`.z.pi`.z.pp`.z.ph`.z.ws`.z.pw;

/ per-phase handler table - name, priority (lower runs first), func; ties break by registration order
phasetableschema:([]name:`symbol$();priority:`long$();func:());

/ empty list result shape
emptylist:([]phase:`symbol$();name:`symbol$();priority:`long$());

/ ============================================================
/ internal helpers - shared
/ ============================================================

upsertphase:{[t;nm;pri;func]
  / replace any existing row for this name, then append - keeps names unique within a phase
  (delete from t where name=nm) upsert (nm;pri;func)
  };

/ ============================================================
/ internal helpers - simple (fan-out) events
/ ============================================================

runobserver:{[event;nm;func;arg]
  / apply one observer under protection - a throw is logged at warn and swallowed so the chain continues
  @[func;arg;{[event;nm;e] .z.m.logwarn[`handlers;"observer ",string[nm]," on ",string[event]," failed: ",e]}[event;nm]];
  };

runoriginal:{[event;arg]
  / apply the captured pre-existing handler last, isolated the same way as registered observers
  @[.z.m.original event;arg;{[event;e] .z.m.logwarn[`handlers;"original ",string[event]," handler failed: ",e]}[event]];
  };

dispatchsimple:{[event;arg]
  / fan out to every registered observer in priority order, then run the captured original last, each isolated
  t:`priority xasc .z.m.registry event;
  runobserver[event;;;arg]'[t`name;t`func];
  runoriginal[event;arg];
  };

installsimple:{[event]
  / on first registration for an event, capture whatever is currently bound (KDB-X default if unset) and install the dispatcher
  .z.m.original[event]:@[value;event;{(::)}];
  .z.m.registry[event]:phasetableschema;
  set[event;dispatchsimple[event;]];
  };

registersimple:{[event;nm;pri;func]
  / lazily install on first use, then add or replace this handler; priority orders the fan-out
  if[not event in key .z.m.original;installsimple event];
  .z.m.registry[event]:upsertphase[.z.m.registry event;nm;pri;func];
  .z.m.loginfo[`register;"registered observer ",string[nm]," on ",string[event]];
  };

removesimple:{[event;nm]
  / drop the named handler; the dispatcher and captured original keep firing regardless of remaining count
  if[not event in key .z.m.registry;.z.m.loginfo[`remove;"no observers registered on ",string[event],"; nothing to remove for ",string[nm]];:(::)];
  if[not nm in exec name from .z.m.registry event;.z.m.loginfo[`remove;"observer ",string[nm]," not registered on ",string[event],"; nothing to remove"];:(::)];
  .z.m.registry[event]:delete from .z.m.registry event where name=nm;
  .z.m.loginfo[`remove;"removed observer ",string[nm]," on ",string[event]];
  };

simplelist:{[event]
  / uniform ([]phase;name;priority) view - simple events carry a null phase, priority order
  select phase:`,name,priority from `priority xasc $[event in key .z.m.registry;.z.m.registry event;phasetableschema]
  };

/ ============================================================
/ internal helpers - phased (pre -> exec -> post) events
/ ============================================================

runpost:{[event;nm;func;result;args]
  / apply one post handler under protection - side-effect only, never alters the result; a throw is logged at warn and swallowed
  .[func;(result;args);{[event;nm;e] .z.m.logwarn[`handlers;"post handler ",string[nm]," on ",string[event]," failed: ",e]}[event;nm]];
  };

runpostall:{[event;result;args]
  / run every post handler for event in priority order, each isolated, with the uniform func[result;args] signature
  t:`priority xasc .z.m.post event;
  runpost[event;;;result;args]'[t`name;t`func];
  };

dispatchphased:{[event;req]
  / thread the request through pre (transform, unprotected) -> exec owner (unprotected) -> transform
  / (rewrite result, chained, unprotected) -> post (observe, protected)
  pres:exec func from `priority xasc .z.m.pre event;
  req:{[acc;f] f acc}/[req;pres];
  r:.z.m.ownerfunc[event] req;
  xforms:exec func from `priority xasc .z.m.transform event;
  r:{[acc;f] f acc}/[r;xforms];
  runpostall[event;r;enlist req];
  r
  };

dispatchpw:{[u;p]
  / .z.pw is the only binary phased event - the owner sees the real password; post handlers see it redacted to "***"; no pre
  r:.z.m.ownerfunc[`.z.pw][u;p];
  xforms:exec func from `priority xasc .z.m.transform `.z.pw;
  r:{[acc;f] f acc}/[r;xforms];
  runpostall[`.z.pw;r;(u;"***")];
  r
  };

installphased:{[event]
  / install the dispatcher on first exec registration - create the empty pre/post tables and bind the event
  / .z.ph is the only phased event KDB-X ships a default handler for, and \x cannot restore it - capture it to put back on remove
  if[event~`.z.ph;.z.m.original[event]:@[value;event;{(::)}]];
  .z.m.pre[event]:phasetableschema;
  .z.m.transform[event]:phasetableschema;
  .z.m.post[event]:phasetableschema;
  set[event;$[event~`.z.pw;dispatchpw;dispatchphased[event;]]];
  };

registerexec:{[event;nm;pri;func]
  / single owner - a different name claiming an owned event is rejected; the same name reclaims (idempotent re-init)
  if[event in key .z.m.owner;
    if[not nm~.z.m.owner event;
      .z.m.logerr[`register;err:"di.torq.handlers: ",string[event]," already owned by ",string[.z.m.owner event]," - call remove first"];'err]];
  .z.m.owner[event]:nm;
  / update the owner function in place if the dispatcher is installed (it reads ownerfunc fresh), else install on first exec
  .z.m.ownerfunc[event]:func;
  .z.m.ownerpri[event]:pri;
  if[not event in key .z.m.pre;installphased event];
  .z.m.loginfo[`register;"registered exec owner ",string[nm]," on ",string[event]];
  };

/ the three satellite phases (pre/transform/post) all key their own registry table by event; pick it by phase
satellitetable:{[phase] $[phase~`pre;.z.m.pre;phase~`transform;.z.m.transform;.z.m.post]};

registerprepost:{[event;phase;nm;pri;func]
  / pre/transform/post cannot attach before an exec owner exists - the dispatcher is only live once exec is registered
  if[not event in key .z.m.ownerfunc;
    .z.m.logerr[`register;err:"di.torq.handlers: cannot register ",string[phase]," on ",string[event]," before an exec owner exists - register the exec phase first"];'err];
  $[phase~`pre;.z.m.pre[event]:upsertphase[.z.m.pre event;nm;pri;func];
    phase~`transform;.z.m.transform[event]:upsertphase[.z.m.transform event;nm;pri;func];
    .z.m.post[event]:upsertphase[.z.m.post event;nm;pri;func]];
  .z.m.loginfo[`register;"registered ",string[phase]," handler ",string[nm]," on ",string[event]];
  };

removeprepost:{[event;phase;nm]
  / drop a pre/transform/post handler; the dispatcher stays installed regardless of remaining count
  tbl:satellitetable phase;
  if[not event in key tbl;.z.m.loginfo[`remove;"no ",string[phase]," handlers on ",string[event],"; nothing to remove for ",string[nm]];:(::)];
  if[not nm in exec name from tbl event;.z.m.loginfo[`remove;string[phase]," handler ",string[nm]," not registered on ",string[event],"; nothing to remove"];:(::)];
  $[phase~`pre;.z.m.pre[event]:delete from .z.m.pre event where name=nm;
    phase~`transform;.z.m.transform[event]:delete from .z.m.transform event where name=nm;
    .z.m.post[event]:delete from .z.m.post event where name=nm];
  .z.m.loginfo[`remove;"removed ",string[phase]," handler ",string[nm]," on ",string[event]];
  };

removeexec:{[event;nm]
  / relinquish ownership only if this name owns it, restore the KDB-X default, and clear all phased state for the event
  if[not event in key .z.m.owner;.z.m.loginfo[`remove;"no exec owner on ",string[event],"; nothing to remove for ",string[nm]];:(::)];
  if[not nm~.z.m.owner event;
    .z.m.logerr[`remove;err:"di.torq.handlers: ",string[event]," is owned by ",string[.z.m.owner event],", not ",string[nm]];'err];
  / .z.ph ships a default handler that \x expunges rather than restores, so put the captured original back; every other phased event \x-restores its built-in default
  $[(event in key .z.m.original) and not (::)~.z.m.original event;set[event;.z.m.original event];system"x ",string[event]];
  .z.m.owner:.z.m.owner _ event;
  .z.m.ownerfunc:.z.m.ownerfunc _ event;
  .z.m.ownerpri:.z.m.ownerpri _ event;
  .z.m.original:.z.m.original _ event;
  .z.m.pre:.z.m.pre _ event;
  .z.m.transform:.z.m.transform _ event;
  .z.m.post:.z.m.post _ event;
  .z.m.loginfo[`remove;"removed exec owner ",string[nm]," on ",string[event],"; restored default"];
  };

phasedlist:{[event]
  / uniform ([]phase;name;priority) view in dispatch order - pre rows, the exec owner, transform rows, then post rows
  pre:select phase:`pre,name,priority from `priority xasc .z.m.pre event;
  xform:select phase:`transform,name,priority from `priority xasc .z.m.transform event;
  post:select phase:`post,name,priority from `priority xasc .z.m.post event;
  owner:([]phase:enlist `exec;name:enlist .z.m.owner event;priority:enlist .z.m.ownerpri event);
  pre,owner,xform,post
  };

/ ============================================================
/ public api
/ ============================================================

register:{[event;phase;nm;pri;func]
  / register a handler for a .z.* event - phase is ` for simple events, one of `pre`exec`transform`post for phased events
  if[not -11h=type event;.z.m.logerr[`register;err:"di.torq.handlers: event must be a symbol"];'err];
  if[not -11h=type phase;.z.m.logerr[`register;err:"di.torq.handlers: phase must be a symbol (` for simple, `pre`exec`transform`post for phased)"];'err];
  if[not -11h=type nm;.z.m.logerr[`register;err:"di.torq.handlers: name must be a symbol"];'err];
  if[not type[pri] within -7 -5h;.z.m.logerr[`register;err:"di.torq.handlers: priority must be an integer"];'err];
  if[not type[func] within 100 112h;.z.m.logerr[`register;err:"di.torq.handlers: func must be a function"];'err];
  pri:"j"$pri;
  $[event in observerevents;
    [if[not null phase;.z.m.logerr[`register;err:"di.torq.handlers: ",string[event]," is a simple event - phase must be ` (null)"];'err];
     registersimple[event;nm;pri;func]];
    event in phasedevents;
    [if[not phase in `pre`exec`transform`post;.z.m.logerr[`register;err:"di.torq.handlers: ",string[event]," is a phased event - phase must be one of `pre`exec`transform`post"];'err];
     if[(event~`.z.pw) and phase~`pre;.z.m.logerr[`register;err:"di.torq.handlers: .z.pw has no pre phase - register exec (owner, real password), transform (rewrite result), or post (redacted watcher)"];'err];
     $[phase~`exec;registerexec[event;nm;pri;func];registerprepost[event;phase;nm;pri;func]]];
    [.z.m.logerr[`register;err:"di.torq.handlers: unsupported event ",string[event]];'err]];
  };

remove:{[event;phase;nm]
  / remove a handler - phase mirrors register; removing an exec restores the KDB-X default and clears the event's phased state
  if[not -11h=type event;.z.m.logerr[`remove;err:"di.torq.handlers: event must be a symbol"];'err];
  if[not -11h=type phase;.z.m.logerr[`remove;err:"di.torq.handlers: phase must be a symbol"];'err];
  if[not -11h=type nm;.z.m.logerr[`remove;err:"di.torq.handlers: name must be a symbol"];'err];
  $[event in observerevents;
    [if[not null phase;.z.m.logerr[`remove;err:"di.torq.handlers: ",string[event]," is a simple event - phase must be ` (null)"];'err];
     removesimple[event;nm]];
    event in phasedevents;
    [if[not phase in `pre`exec`transform`post;.z.m.logerr[`remove;err:"di.torq.handlers: ",string[event]," is a phased event - phase must be one of `pre`exec`transform`post"];'err];
     $[phase~`exec;removeexec[event;nm];removeprepost[event;phase;nm]]];
    [.z.m.logerr[`remove;err:"di.torq.handlers: unsupported event ",string[event]];'err]];
  };

list:{[event]
  / return the registered handlers for a single event as a ([]phase;name;priority) table
  if[not -11h=type event;.z.m.logerr[`list;err:"di.torq.handlers: event must be a symbol"];'err];
  :$[event in observerevents; simplelist event;
     event in phasedevents;   $[event in key .z.m.owner;phasedlist event;emptylist];
     [.z.m.logerr[`list;err:"di.torq.handlers: unsupported event ",string[event]];'err]];
  };

init:{[deps]
  / initialise di.torq.handlers - validate the required log dependency and set up empty registries (idempotent)
  / deps: a dict with a `log key; log must be a dict of binary {[c;m]} functions with `info`warn`error keys
  / example: handlers.init[enlist[`log]!enlist logdep]
  if[99h<>type deps;
    '"di.torq.handlers: deps must be a dict with `log key"];
  if[not `log in key deps;
    '"di.torq.handlers: log dependency is required; pass `info`warn`error functions keyed on `log"];
  if[99h<>type deps`log;
    '"di.torq.handlers: log value must be a dict; pass `info`warn`error functions"];
  if[not all `info`warn`error in key deps`log;
    '"di.torq.handlers: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  .z.m.loginfo:(deps`log)`info;
  .z.m.logwarn:(deps`log)`warn;
  .z.m.logerr:(deps`log)`error;
  / initialise the registries only on first init - a direct (module-rewritten) reference detects prior setup
  if[not @[{.z.m.registry;1b};::;0b];
    .z.m.registry:(`$())!();
    .z.m.original:(`$())!();
    .z.m.owner:(`$())!();
    .z.m.ownerfunc:(`$())!();
    .z.m.ownerpri:(`$())!();
    .z.m.pre:(`$())!();
    .z.m.transform:(`$())!();
    .z.m.post:(`$())!();
    ];
  .z.m.loginfo[`init;"di.torq.handlers initialised"];
  };
