/ library for selecting backend servers from a registered pool based on servertype or attribute requirements

/ registered server pool - populated by addserverfull / addserverattr / addserver
servers:([serverid:`u#`int$()]
  handle:`int$();
  procname:`symbol$();
  servertype:`symbol$();
  hpup:`symbol$();
  active:`boolean$();
  lastp:`timestamp$();
  hits:`int$();
  attributes:();
  disconnecttime:`timestamp$());

/ autoincrement counter for server IDs
serverid:0i;

/ attribute-requirement keys that steer the matcher rather than name a server attribute
ctrlkeys:`servertype`attributetype`besteffort;

raiseerror:{[ctx;msg]
  / internal - log an error under ctx then signal it, so failures are observable as well as thrown
  .z.m.logerr[ctx;msg];
  '"di.serverselect: ",string[ctx],": ",msg;
  };

signalnomatch:{[ctx;msg]
  / internal - signal a no-match CONDITION from the matching engine WITHOUT logging. a miss is not a
  / fault: getserverids decides the level, logging a per-servertype miss at warn (another requested
  / type may still match) and an all-types miss at error via raiseerror. logging here instead would
  / emit an ERROR line for every routine partial match on a multi-servertype query
  '"di.serverselect: ",string[ctx],": ",msg;
  };

requiredict:{[ctx;nm;d]
  / internal - insist on a genuine SYMBOL-KEYED dictionary, not merely something of type 99h.
  / a keyed table is 99h too, so a bare type check lets one through; it then reaches attributematch's
  / `key avail` and yields garbage scoring or a raw 'length rather than a clear error. a symbol-keyed
  / dict is the only shape the matcher can use, and a keyed table's key is a TABLE (98h), so the one
  / key-type test excludes both a keyed table and a dict keyed on anything but symbols
  / NB the empty dict ()!() keys on an empty GENERAL list (type 0h), not on an empty symbol vector,
  / so an 11h-only test would reject the single most common attributes value there is
  if[99h<>type d;raiseerror[ctx;nm," must be a dictionary; got type ",string type d]];
  if[not $[0=count k:key d;not 98h=type k;11h=type k];
    raiseerror[ctx;nm," must be a symbol-keyed dictionary; got keys of type ",string type k]];
  };

requireinit:{[ctx]
  / internal - every public entry point needs init to have run first. without this guard a bare read
  / of an unwritten .z.m name surfaces as a raw '.m.di.0serverselect.<name> error, leaking the mangled
  / internal namespace to the caller instead of naming the actual problem. signals plainly rather than
  / via raiseerror - there is no logger to log through yet.
  / getapimeta is deliberately NOT guarded: it is pure data and di.torq collects it at startup, which
  / may be before this module's init has run
  if[not `logerr in key .z.m;'"di.serverselect: ",string[ctx],": init must be called first"];
  };

selectorarity:{[f]
  / internal - arity of f WHERE Q CAN TELL, else 0N.
  / a lambda reports its own parameter list. a projection's REMAINING arity is its underlying
  / function's rank minus the arguments already supplied - counting elided (::) placeholders alone is
  / wrong, because a trailing partial application such as f[x] carries none at all and would read as
  / arity 0, rejecting a perfectly valid strategy. the underlying rank is resolved recursively so a
  / projection OF a projection also works.
  / primitives, compositions and adverb-derived functions report nothing usable, so they yield 0N and
  / the caller accepts them unchecked - admitting the check does not apply beats rejecting valid input
  :$[100h=type f; count value[f]1;
     104h=type f; $[null b:selectorarity first value f;
                     0N;
                     b-count where not (::)~/:1_value f];
     0N];
  };

getopt:{[deps;k;dflt]
  / internal - read an optional config key from the deps dict, falling back to a default
  $[k in key deps;deps k;dflt]
  };

checkopt:{[deps;k;ok;what]
  / internal - validate an optional config value's TYPE at init, so a misconfiguration fails loudly
  / at startup instead of silently at first use
  if[k in key deps;
    if[not ok deps k;'"di.serverselect: ",string[k]," must be ",what]];
  };

init:{[deps]
  / wire the injected logger - required, no silent fallback - and the optional config.
  / deps keys:
  /   log               (required) `info`warn`error!{[c;m]} dict - binary, already conforming.
  /                     a raw monadic kx.log instance is NOT adapted here and will 'rank at first use
  /   cp                (optional) current-time fn, default {.z.p}. stamps disconnecttime and drives
  /                     removeinactive; override it to fast-forward in tests without sleeping
  /   clearinactivetime (optional) timespan, default 0D01:00. NOT read by any function here -
  /                     removeinactive is caller-invoked, so this is the age di.torq passes it when
  /                     it schedules the purge, mirroring di.dataaccess's requestkeeptime
  / e.g. di.serverselect.init[enlist[`log]!enlist logdep]
  if[99h<>type deps;
    '"di.serverselect: deps must be a dict with `log key"];
  if[not `log in key deps;
    '"di.serverselect: log dependency is required; pass `info`warn`error functions keyed on `log"];
  if[99h<>type deps`log;
    '"di.serverselect: log value must be a dict; pass `info`warn`error functions"];
  if[not all (`info`warn`error) in key deps`log;
    '"di.serverselect: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  checkopt[deps;`cp;{type[x] within 100 112h};"a function"];
  checkopt[deps;`clearinactivetime;{-16h=type x};"a timespan"];
  checkopt[deps;`maxcrossproduct;{(-7h=type x) and 0<x};"a positive long"];
  .z.m.loginfo:deps[`log]`info;
  .z.m.logwarn:deps[`log]`warn;
  .z.m.logerr:deps[`log]`error;
  .z.m.cp:getopt[deps;`cp;{.z.p}];
  .z.m.clearinactivetime:getopt[deps;`clearinactivetime;0D01:00];
  .z.m.maxcrossproduct:getopt[deps;`maxcrossproduct;1000000];
  / seed the live selection strategy from the built-in default; setselector replaces it at runtime
  .z.m.selector:selector;
  };

nextserverid:{
  / internal - increment and return the next unique server ID
  .z.m.serverid:serverid+1i;
  :.z.m.serverid;
  };

updatestats:{[sid]
  / internal - update last-access timestamp and hit count for a single server
  / keyed on serverid (unique) rather than handle, which may be shared by multiple servers
  .z.m.servers:update lastp:.z.p,hits:hits+1i from servers where serverid=sid;
  };

addserverfull:{[h;pname;st;hp;att]
  / register a server with full details: handle, procname, servertype, hpup and attribute dictionary
  requireinit`addserverfull;
  if[not -6h=type h;raiseerror[`addserverfull;"handle must be an int; got type ",string type h]];
  if[not -11h=type st;raiseerror[`addserverfull;"servertype must be a symbol; got type ",string type st]];
  / attributes MUST be a dict. the column is a general list, so a non-dict registers happily and then
  / surfaces much later, in a different function, as a raw unlogged 'type from attributematch's
  / `key avail`. worse, if the very first registration is malformed the column takes that value's
  / type and every subsequent well-formed registration fails too
  requiredict[`addserverfull;"attributes";att];
  .z.m.loginfo[`addserverfull;"registering server: handle=",(string h),", procname=",string[pname],", type=",string st];
  .z.m.servers:servers upsert (nextserverid[];h;pname;st;hp;1b;0Np;0i;att;0Np);
  };

addserverattr:{[h;st;att]
  / register a server with servertype and attributes; procname and hpup default to null
  addserverfull[h;`;st;`;att];
  };

addserver:{[h;st]
  / register a server with no attributes; procname and hpup default to null
  addserverfull[h;`;st;`;()!()];
  };

setserveractive:{[h;a]
  / mark a registered server active (1b) or inactive (0b); called on connect and disconnect.
  / stamps disconnecttime on the active->inactive transition and clears it on reactivation, so
  / removeinactive can age out servers that disconnected and never came back
  requireinit`setserveractive;
  if[not -6h=type h;raiseerror[`setserveractive;"handle must be an int; got type ",string type h]];
  if[not -1h=type a;raiseerror[`setserveractive;"active flag must be a boolean; got type ",string type a]];
  .z.m.loginfo[`setserveractive;"marking handle=",(string h)," active=",string a];
  / the conditional is hoisted OUT of the update deliberately: inside q-sql, $ resolves as the dyadic
  / cast operator rather than the cond special form, so an inline $[a;0Np;.z.m.cp[]] throws 'rank
  dtime:$[a;0Np;.z.m.cp[]];
  .z.m.servers:update active:a,disconnecttime:dtime from servers where handle=h;
  };

setserveridactive:{[sid;a]
  / mark ONE registration active/inactive by serverid, independent of any other servertype sharing
  / the same physical handle. setserveractive keys on handle and is the right shape for a genuine
  / disconnect - a closed handle really does take every registration on it down together - but it
  / cannot express "pull just this servertype out of routing". updatestats already keys on serverid
  / precisely because a handle may be shared; this closes the same gap for activation.
  / stamps and clears disconnecttime exactly as setserveractive does, so removeinactive ages a
  / registration retired this way out on the same terms
  requireinit`setserveridactive;
  if[not -6h=type sid;raiseerror[`setserveridactive;"serverid must be an int; got type ",string type sid]];
  if[not -1h=type a;raiseerror[`setserveridactive;"active flag must be a boolean; got type ",string type a]];
  .z.m.loginfo[`setserveridactive;"marking serverid=",(string sid)," active=",string a];
  / hoisted out of the update for the same reason as setserveractive - $ is the cast operator in q-sql
  dtime:$[a;0Np;.z.m.cp[]];
  / no existence check: an unmatched serverid is a natural no-op, matching setserveractive's own
  / established behaviour on an unregistered handle. do not add asymmetric strictness here
  .z.m.servers:update active:a,disconnecttime:dtime from servers where serverid=sid;
  };

removeinactive:{[age]
  / purge inactive servers that disconnected more than age ago, to bound growth of the server table.
  / setserveractive[h;0b] only flips a flag, so without this a process that connected once and went
  / away stays in the table forever. caller-invoked - di.torq schedules it with clearinactivetime
  requireinit`removeinactive;
  if[not -16h=type age;raiseerror[`removeinactive;"age must be a timespan; got type ",string type age]];
  if[null age;raiseerror[`removeinactive;"age must not be null"]];
  if[age<0D;raiseerror[`removeinactive;"age must not be negative; got ",string age]];
  / 0Wn means "retain forever" and MUST short-circuit: it cannot be expressed by the comparison below,
  / because disconnecttime+0Wn overflows the timestamp range (wrapping back to the year 1734), so every
  / inactive row would compare as aged out - the exact opposite of an infinite retention. 0Nn is
  / rejected above for the same reason: disconnecttime+0Nn is 0Np, and cp[]>0Np is true for everything
  if[0Wn=age;:()];
  .z.m.servers:delete from servers where not active,not null disconnecttime,.z.m.cp[]>disconnecttime+age;
  };

getserverstable:{[]
  / return the current registered server table
  requireinit`getserverstable;
  :servers;
  };

addserversfromtable:{[proctypes;conntable]
  / register active servers from a connection table filtered by proctype
  / conntable must have columns: w (int handle), proctype (symbol), attributes (dict per row)
  / optional columns: procname (symbol), hpup (symbol) - populated from conntable if present
  / pass proctypes:`ALL to register all process types
  requireinit`addserversfromtable;
  / unkeyed table required: cols works on a keyed table but the select below does not, so without
  / this the caller gets a raw 'type instead of a message naming the argument
  if[not 98h=type conntable;
    raiseerror[`addserversfromtable;"conntable must be an unkeyed table; got type ",string type conntable]];
  if[not all `w`proctype`attributes in cols conntable;
    raiseerror[`addserversfromtable;
      "conntable must have columns w, proctype and attributes; got: ",", " sv string cols conntable]];
  activehandles:(0i;0Ni),exec handle from servers where active;
  rows:select from conntable where
    ((proctype in proctypes) or proctypes~`ALL),
    not w in activehandles;
  .z.m.loginfo[`addserversfromtable;"registering ",(string count rows)," servers from connection table"];
  pnames:$[`procname in cols rows; rows`procname; count[rows]#`];
  hpups:$[`hpup in cols rows; rows`hpup; count[rows]#`];
  addserverfull'[rows`w;pnames;rows`proctype;hpups;rows`attributes];
  };

attributematch:{[req;avail]
  / compute match result for each key in req against what avail advertises
  / returns dict of attrname!(complete_match_bool;matched_values) for each required attribute key
  / keys present in req but absent in avail return (0b;())
  vals:key[req] inter key avail;
  notpresent:noval!(count noval:key[req] except key avail)#enlist(0b;());
  :notpresent,vals!{($[0>type y;x~y;all x in y];(x,()) inter y,())}'[req vals;avail vals];
  };

getservers:{[nameortype;lookups;req]
  / look up active servers by servertype or procname with per-attribute match scoring
  / nameortype: `servertype or `procname; pass ` as lookups to return all active servers
  / req: attribute requirements dict - use ()!() for no attribute filtering
  / returns table with attribmatch column showing (complete_bool;matched_values) per attribute key
  requireinit`getservers;
  if[(not `~lookups) and not nameortype in `servertype`procname;
    raiseerror[`getservers;"nameortype must be `servertype or `procname; got: ",string nameortype]];
  requiredict[`getservers;"req";req];
  r:$[`~lookups;
    select serverid,procname,servertype,hpup,handle,lastp,attributes from servers where active;
    nameortype~`servertype;
    select serverid,procname,servertype,hpup,handle,lastp,attributes from servers where active,servertype in lookups;
    select serverid,procname,servertype,hpup,handle,lastp,attributes from servers where active,procname in lookups];
  if[0=count r;:update attribmatch:attributes from r];
  am:attributematch[req] each r`attributes;
  :update attribmatch:am from r;
  };

selector:{[servertable;selection]
  / pick one row from servertable using the given strategy
  / selection: `roundrobin (least recently used), `any (random), `last (most recently used)
  requireinit`selector;
  if[not selection in `roundrobin`any`last;
    raiseerror[`selector;"unknown selection strategy: ",string selection]];
  :$[selection=`roundrobin; first `lastp xasc servertable;
     selection=`any;        rand servertable;
     last `lastp xasc servertable];
  };

setselector:{[f]
  / replace the strategy getserverbytype uses to pick one row from a candidate table.
  / the built-in selector stays exported and unchanged - pass it back here to restore the default
  requireinit`setselector;
  if[not type[f] within 100 112h;raiseerror[`setselector;"selector must be a function; got type ",string type f]];
  / check arity HERE where the mistake is, not at the next getserverbytype. a monadic or niladic
  / strategy used to be accepted happily and then throw a bare 'rank from inside the module, far from
  / the call site. 0N means q cannot report an arity for this function type, so it is accepted
  ar:selectorarity f;
  if[not null ar;
    if[2<>ar;
      raiseerror[`setselector;"selector must take 2 arguments (servertable;selection); got ",string ar]]];
  .z.m.selector:f;
  };

getserverbytype:{[ptype;serverval;selection]
  / return a single server attribute value for a servertype using the given selection strategy
  / ptype: servertype symbol; serverval: column to return e.g. `handle or `hpup; selection: `roundrobin`any`last
  / dispatches through the live .z.m.selector so setselector can override the strategy
  requireinit`getserverbytype;
  r:getservers[`servertype;ptype;()!()];
  if[not count r;:()];
  r:.z.m.selector[r;selection];
  updatestats[r`serverid];
  :r serverval;
  };

gethandlebytype:getserverbytype[;`handle;];
gethpbytype:getserverbytype[;`hpup;];

normreq:{[req]
  / internal - promote atom attribute-requirement values to one-element lists, so a caller may write
  / (enlist`date)!enlist 2024.01.01 as well as the enlist form. getservers already tolerates an atom
  / via attributematch; without this the cross matcher threw a raw, unlogged 'rank on the same input.
  / req is PURE requirements by this point - control keys are split off at the boundary - so every
  / value is promoted, including one whose key happens to be spelled like a control key
  :(key req)!{(),x} each value req;
  };

raisecaught:{[ctx;msg]
  / internal - log an error the engine already prefixed, then re-signal it VERBATIM. the engine's own
  / text ("no servers match hdb requested attributes") is more specific than anything composed here,
  / and signalnomatch deliberately does not log - the boundary decides the level. used on the
  / single-servertype path, where there is nothing to tolerate: one type missing IS the whole answer
  .z.m.logerr[ctx;msg];
  'msg;
  };

fanoutids:{[req;besteffort;attype;typ]
  / internal - resolve one servertype's ids, tolerating a miss. a miss is NOT a query failure: another
  / requested type may match, and getserverids errors only when every type comes back empty. this
  / revives getserverids' all-empty guard, which was unreachable while this call threw instead
  :@[getserveridstype[req;besteffort;attype;];typ;
    {[t;e] .z.m.logwarn[`getserverids;"no servers matched servertype ",string[t],": ",e];()}[typ]];
  };

getserverids:{[att]
  / return server IDs matching a servertype list or attribute requirement dictionary
  / att: symbol list of servertypes, or dict of attribute requirements (optionally keyed on `servertype)
  / dispatch the symbol-list path to getserveridsbytype and the dict path to getserveridstype
  requireinit`getserverids;
  if[99h<>type att; :getserveridsbytype att];
  / TWO request shapes. flat (the original): control keys sit alongside the attribute requirements, so
  / the three control names are reserved and an attribute cannot be called servertype/besteffort/
  / attributetype. nested: an `attrs key holds the requirements EXPLICITLY, leaving the rest of the
  / dict to the controls - which lets an attribute carry any name at all, control names included.
  / both are supported; nested is the way out of the namespace collision, flat stays for compatibility
  nested:`attrs in key att;
  if[nested;
    requiredict[`getserverids;"attrs";att`attrs];
    / in the nested form EVERY top-level key that is not `attrs is a control, so an unrecognised one
    / would be silently swallowed - dropping a requirement left outside attrs by a half-migrated
    / caller, or ignoring a mistyped control. the flat form cannot have this problem (an unknown key
    / there is simply a requirement), so the nested form has to be strict to stay as safe
    if[count unknown:(key att) except `attrs,ctrlkeys;
      raiseerror[`getserverids;"unknown keys beside attrs: ",(", " sv string unknown),
        "; only attrs and the control keys belong at the top level of an attrs request"]]];
  ctl:$[nested;`attrs _ att;(key[att] inter ctrlkeys)#att];
  req:normreq $[nested;att`attrs;ctrlkeys _ att];
  / controls are validated HERE, at the boundary, and never inside getserveridstype: the fan-out below
  / runs under a protected apply, so an error raised deeper down is caught and downgraded to a "this
  / servertype did not match" warning. a misconfigured request is categorically not a per-type miss and
  / must stay loud. before this, besteffort:0 (int) silently kept the 1b default and an unknown
  / attributetype silently fell back to cross matching
  if[`servertype in key ctl;
    if[not 11h=abs type ctl`servertype;
      raiseerror[`getserverids;"servertype must be a symbol or symbol list; got type ",string type ctl`servertype]]];
  if[`besteffort in key ctl;
    if[not -1h=type ctl`besteffort;
      raiseerror[`getserverids;"besteffort must be a boolean; got type ",string type ctl`besteffort]]];
  if[`attributetype in key ctl;
    if[not -11h=type ctl`attributetype;
      raiseerror[`getserverids;"attributetype must be a symbol; got type ",string type ctl`attributetype]];
    if[not (ctl`attributetype) in `cross`independent;
      raiseerror[`getserverids;"attributetype must be `cross or `independent; got: ",string ctl`attributetype]]];
  / a nested/general-list requirement value (type 0h) would crash the cross matcher with a raw 'type
  if[count badkeys:(key req) where 0h=type each value req;
    raiseerror[`getserverids;
      "attribute requirement values must be atoms or simple vectors; nested/mixed for: ",", " sv string badkeys]];
  besteffort:$[`besteffort in key ctl;ctl`besteffort;1b];
  attype:$[`attributetype in key ctl;ctl`attributetype;`cross];
  / bound the cross product before building it. cost is the PRODUCT of the requirement value counts, so
  / a request a caller forwards straight from a client can get very large very cheaply. only cross
  / matching builds it - independent matching is not combinatorial, so it is not bounded here.
  / maxcrossproduct:0W disables the bound
  / count req guard is NOT optional: prd of an empty list is () rather than 1, so an empty requirement
  / dict would make the comparison return () and if[()] throw a raw 'type
  if[attype=`cross;
    if[.z.m.maxcrossproduct<sz:$[count req;prd count each value req;1];
      raiseerror[`getserverids;"requirement cross product of ",(string sz)," exceeds maxcrossproduct ",
        string .z.m.maxcrossproduct]]];
  / distinct: a repeated servertype would otherwise be resolved twice and return the same serverids in
  / two groups, so a caller dispatching on the result would query the same server twice. the symbol
  / path (getserveridsbytype) already dedupes; these two paths disagreed before.
  / the single-servertype/`all path does NOT go through the tolerant fan-out: there is no sibling type
  / to fall back on, so its error is logged once and re-signalled with the engine's specific wording
  serverids:$[`servertype in key ctl;
    raze fanoutids[req;besteffort;attype] each distinct (),ctl`servertype;
    @[getserveridstype[req;besteffort;attype];`all;raisecaught[`getserverids;]]];
  if[all 0=count each serverids;
    raiseerror[`getserverids;"no servers match requested attributes"]];
  :serverids;
  };

getserveridsbytype:{[att]
  / internal - resolve server IDs for a servertype symbol or symbol list
  / validates each requested type is registered and currently active
  requireinit`getserveridsbytype;
  if[not 11h=abs type att;
    raiseerror[`getserveridsbytype;"servertype must be a symbol list (11h) or attribute dict (99h)"]];
  servertype:distinct att,();
  activeservers:exec distinct servertype from servers where active;
  allservers:exec distinct servertype from servers;
  activeserversmsg:". available servers: ",", " sv string activeservers;
  if[any null att;
    raiseerror[`getserveridsbytype;"null servertype passed as argument",activeserversmsg]];
  if[count servertype except activeservers;
    raiseerror[`getserveridsbytype;$[max not servertype in allservers;
        "not valid servers: ",", " sv string servertype except allservers;
        "requested servers currently inactive: ",", " sv string servertype except activeservers
      ],activeserversmsg]];
  :(exec serverid by servertype from servers where active)[servertype];
  };

getserveridstype:{[req;besteffort;attype;typ]
  / internal - filter active servers of one servertype by pure attribute requirements.
  / control values arrive as explicit arguments: this function no longer parses them out of the
  / requirement dict, which is what made the three control names unusable as attribute names
  svrs:$[typ=`all;
    exec serverid!attributes from servers where active;
    exec serverid!attributes from servers where active,servertype=typ];
  res:$[attype=`independent;
    getserversindependent[req;svrs;besteffort];
    getserverscross[req;svrs;besteffort]];
  serverids:first value flip $[99h=type res; key res; res];
  if[all 0=count each serverids;
    signalnomatch[`getserveridstype;"no servers match ",string[typ]," requested attributes"]];
  :serverids;
  };

/ internal - build a cross product table from a nested dictionary
buildcross:{(cross/){flip (enlist y)#x}[x] each key x};

getserversinitial:{[req;att]
  / internal - initial filter shared by cross and independent matching
  / drops servers missing any required attribute key, ranks survivors by coverage
  if[0=count req; :([]serverid:enlist key att)];
  att:(where all each (key req) in/: key each att)#att;
  if[not count att;signalnomatch[`getserversinitial;"no servers report all requested attributes"]];
  s:update serverid:key att from value req in'/: (key req)#/:att;
  s:s idesc value min each sum each' `serverid xkey s;
  s:`serverid xkey 0!(key req) xgroup s;
  :s;
  };

getserverscross:{[req;att;besteffort]
  / internal - find servers satisfying the cross product of all attribute requirements
  / each attribute combination must be coverable by a single server
  if[0=count req; :([]serverid:enlist key att)];
  s:getserversinitial[req;att];
  reqcross:buildcross[req];
  / scan through each server group accumulating which cross-product rows have been covered
  util:flip `remaining`found!flip (
    {[x;y;z] (y[0] except found; y[0] inter found:$[0=count y[0];y[0];buildcross x@'where each z])}[req]\
    )[(reqcross;());value s];
  if[(count last util`remaining) and not besteffort;
    signalnomatch[`getserverscross;"cannot satisfy query - cross product of all attributes cannot be matched"]];
  s:1!(0!s) w:where not 0=count each util`found;
  :(key s)!distinct each' flip each util[w]`found;
  };

getserversindependent:{[req;att;besteffort]
  / internal - find servers satisfying attribute requirements independently
  / each individual requirement only needs to be matched by one server
  if[0=count req; :([]serverid:enlist key att)];
  s:getserversinitial[req;att];
  / mask out server groups whose contribution is already covered by earlier groups
  filter:(value s)&not -1 _ (0b&(value s) enlist 0),maxs value s;
  alldone:1+first where all each all each' maxs value s;
  if[(null alldone) and not besteffort;
    signalnomatch[`getserversindependent;"cannot satisfy query - not all attributes can be matched"]];
  s:1!(0!s) w:where any each any each' filter;
  :(key s)!{(key x)!(value x)@'where each y key x}[req] each value s&filter w;
  };

getapimeta:{[]
  / this module's api metadata, one row per CALLABLE api function (NOT init/getapimeta - those are
  / plumbing di.torq calls by convention, never registered), for di.torq to collect and register with
  / di.api. names are bare; di.torq applies the process-wide qualification
  :flip `name`public`descrip`params`return!flip(
    (`version;            1b; "module version string";
       "[]";                                                                  "string: version");
    (`addserverfull;      1b; "register a server with handle, procname, servertype, hpup and attributes";
       "[int: handle; symbol: procname; symbol: servertype; symbol: hpup; dict: attributes]";
                                                                             "null");
    (`addserverattr;      1b; "register a server with servertype and attributes; procname and hpup null";
       "[int: handle; symbol: servertype; dict: attributes]";                 "null");
    (`addserver;          1b; "register a server with no attributes; procname and hpup null";
       "[int: handle; symbol: servertype]";                                   "null");
    (`setserveractive;    1b; "mark every registration on a handle active or inactive, stamping disconnecttime";
       "[int: handle; boolean: active]";                                      "null");
    (`setserveridactive;  1b; "mark ONE registration active or inactive by serverid, leaving handle siblings alone";
       "[int: serverid; boolean: active]";                                    "null");
    (`getserverstable;    1b; "return the current registered server table";
       "[]";                                                                  "table: registered servers");
    (`addserversfromtable;1b; "register active servers from a connection table filtered by proctype";
       "[symbol: proctypes or `ALL; table: conntable]";                       "null");
    (`getservers;         1b; "look up active servers by servertype or procname with per-attribute match scoring";
       "[symbol: nameortype; symbol: lookups; dict: requirements]";           "table: servers with attribmatch");
    (`selector;           1b; "pick one row from a candidate table using roundrobin, any or last";
       "[table: servertable; symbol: selection]";                             "dict: the chosen row");
    (`setselector;        1b; "replace the strategy getserverbytype uses to pick one row";
       "[function: selector]";                                                "null");
    (`getserverbytype;    1b; "return one column value for a servertype using the given selection strategy";
       "[symbol: servertype; symbol: column; symbol: selection]";             "any: column value, () if none");
    (`gethandlebytype;    1b; "return one handle for a servertype using the given selection strategy";
       "[symbol: servertype; symbol: selection]";                             "int: handle, () if none");
    (`gethpbytype;        1b; "return one hpup for a servertype using the given selection strategy";
       "[symbol: servertype; symbol: selection]";                             "symbol: hpup, () if none");
    (`getserverids;       1b; "return server ids matching a servertype list or attribute requirement dict";
       "[symbol list: servertypes, or dict: requirements]";                   "list: matching server ids");
    (`removeinactive;     1b; "purge inactive servers that disconnected more than age ago";
       "[timespan: age]";                                                     "null"));
  };
