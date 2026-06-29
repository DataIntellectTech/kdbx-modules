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
  attributes:());

/ autoincrement counter for server IDs
serverid:0i;

init:{[deps]
  / wire injectable dependencies (and any optional config) - must be called before any other function
  / the log dependency is required; there is no fallback
  / deps: a dict with a `log key; the log value is either a kx.log instance or a `info`warn`error
  /   dict of binary {[c;m]} loggers (context symbol, message string) - normalised via normlog
  / example: di.serverselect.init[enlist[`log]!enlist logdep]
  if[99h<>type deps;
    '"di.serverselect: deps must be a dict with `log key"];
  if[not `log in key deps;
    '"di.serverselect: log dependency is required; pass `info`warn`error functions keyed on `log"];
  if[99h<>type deps`log;
    '"di.serverselect: log value must be a dict; pass `info`warn`error functions"];
  if[not all (`info`warn`error) in key deps`log;
    '"di.serverselect: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  .z.m.log:normlog deps`log;
  };

normlog:{[logdict]
  / internal - normalise the injected logger to a binary `info`warn`error!{[c;m]} dict
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

raiseerror:{[ctx;msg]
  / internal - log an error under ctx then signal it, so failures are observable as well as thrown
  .z.m.log[`error][ctx;msg];
  '"di.serverselect: ",string[ctx],": ",msg;
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
  if[not -6h=type h;raiseerror[`addserverfull;"handle must be an int; got type ",string type h]];
  if[not -11h=type st;raiseerror[`addserverfull;"servertype must be a symbol; got type ",string type st]];
  .z.m.log[`info][`addserverfull;"registering server: handle=",(string h),", procname=",string[pname],", type=",string st];
  .z.m.servers:servers upsert (nextserverid[];h;pname;st;hp;1b;0Np;0i;att);
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
  / mark a registered server active (1b) or inactive (0b); called on connect and disconnect
  if[not -6h=type h;raiseerror[`setserveractive;"handle must be an int; got type ",string type h]];
  if[not -1h=type a;raiseerror[`setserveractive;"active flag must be a boolean; got type ",string type a]];
  .z.m.log[`info][`setserveractive;"marking handle=",(string h)," active=",string a];
  .z.m.servers:update active:a from servers where handle=h;
  };

getserverstable:{[]
  / return the current registered server table
  :servers;
  };

addserversfromtable:{[proctypes;conntable]
  / register active servers from a connection table filtered by proctype
  / conntable must have columns: w (int handle), proctype (symbol), attributes (dict per row)
  / optional columns: procname (symbol), hpup (symbol) - populated from conntable if present
  / pass proctypes:`ALL to register all process types
  if[not all `w`proctype`attributes in cols conntable;
    raiseerror[`addserversfromtable;"conntable must have columns w, proctype and attributes; got: ",", " sv string cols conntable];
  ];
  activehandles:(0i;0Ni),exec handle from servers where active;
  rows:select from conntable where
    ((proctype in proctypes) or proctypes~`ALL),
    not w in activehandles;
  .z.m.log[`info][`addserversfromtable;"registering ",(string count rows)," servers from connection table"];
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
  r:$[`~lookups;
    select serverid,procname,servertype,hpup,handle,lastp,attributes from servers where active;
    nameortype~`servertype;
    select serverid,procname,servertype,hpup,handle,lastp,attributes from servers where active,servertype in lookups;
    nameortype~`procname;
    select serverid,procname,servertype,hpup,handle,lastp,attributes from servers where active,procname in lookups;
    raiseerror[`getservers;"nameortype must be `servertype or `procname; got: ",string nameortype]];
  if[0=count r;:update attribmatch:attributes from r];
  am:attributematch[req] each r`attributes;
  :update attribmatch:am from r;
  };

selector:{[servertable;selection]
  / pick one row from servertable using the given strategy
  / selection: `roundrobin (least recently used), `any (random), `last (most recently used)
  :$[selection=`roundrobin; first `lastp xasc servertable;
     selection=`any;        rand servertable;
     selection=`last;       last `lastp xasc servertable;
     raiseerror[`selector;"unknown selection strategy: ",string selection]];
  };

getserverbytype:{[ptype;serverval;selection]
  / return a single server attribute value for a servertype using the given selection strategy
  / ptype: servertype symbol; serverval: column to return e.g. `handle or `hpup; selection: `roundrobin`any`last
  r:getservers[`servertype;ptype;()!()];
  if[not count r;:()];
  r:selector[r;selection];
  updatestats[r`serverid];
  :r serverval;
  };

gethandlebytype:getserverbytype[;`handle;];
gethpbytype:getserverbytype[;`hpup;];

getserverids:{[att]
  / return server IDs matching a servertype list or attribute requirement dictionary
  / att: symbol list of servertypes, or dict of attribute requirements (optionally keyed on `servertype)
  / dispatch the symbol-list path to getserveridsbytype and the dict path to getserveridstype
  if[99h<>type att; :getserveridsbytype att];
  serverids:$[`servertype in key att;
    raze getserveridstype[delete servertype from att] each (),att`servertype;
    getserveridstype[att;`all]];
  if[all 0=count each serverids;
    raiseerror[`getserverids;"no servers match requested attributes"];
  ];
  :serverids;
  };

getserveridsbytype:{[att]
  / internal - resolve server IDs for a servertype symbol or symbol list
  / validates each requested type is registered and currently active
  if[not 11h=abs type att;
    raiseerror[`getserveridsbytype;"servertype must be a symbol list (11h) or attribute dict (99h)"];
  ];
  servertype:distinct att,();
  activeservers:exec distinct servertype from servers where active;
  allservers:exec distinct servertype from servers;
  activeserversmsg:". available servers: ",", " sv string activeservers;
  if[any null att;
    raiseerror[`getserveridsbytype;"null servertype passed as argument",activeserversmsg];
  ];
  if[count servertype except activeservers;
    raiseerror[`getserveridsbytype;
      $[max not servertype in allservers;
        "not valid servers: ",", " sv string servertype except allservers;
        "requested servers currently inactive: ",", " sv string servertype except activeservers
      ],activeserversmsg];
  ];
  :(exec serverid by servertype from servers where active)[servertype];
  };

getserveridstype:{[att;typ]
  / internal - filter active servers by servertype and attribute requirements
  / resolves besteffort and attributetype control keys then dispatches to cross or independent matching
  besteffort:1b;
  attype:`cross;
  svrs:$[typ=`all;
    exec serverid!attributes from servers where active;
    exec serverid!attributes from servers where active,servertype=typ];
  if[`besteffort in key att;
    if[-1h=type att`besteffort; besteffort:att`besteffort];
    att:delete besteffort from att;
  ];
  if[`attributetype in key att;
    if[-11h=type att`attributetype; attype:att`attributetype];
    att:delete attributetype from att;
  ];
  res:$[attype=`independent;
    getserversindependent[att;svrs;besteffort];
    getserverscross[att;svrs;besteffort]];
  serverids:first value flip $[99h=type res; key res; res];
  if[all 0=count each serverids;
    raiseerror[`getserveridstype;"no servers match ",string[typ]," requested attributes"];
  ];
  :serverids;
  };

/ internal - build a cross product table from a nested dictionary
buildcross:{(cross/){flip (enlist y)#x}[x] each key x};

getserversinitial:{[req;att]
  / internal - initial filter shared by cross and independent matching
  / drops servers missing any required attribute key, ranks survivors by coverage
  if[0=count req; :([]serverid:enlist key att)];
  att:(where all each (key req) in/: key each att)#att;
  if[not count att;raiseerror[`getserversinitial;"no servers report all requested attributes"]];
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
    raiseerror[`getserverscross;"cannot satisfy query - cross product of all attributes cannot be matched"];
  ];
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
    raiseerror[`getserversindependent;"cannot satisfy query - not all attributes can be matched"];
  ];
  s:1!(0!s) w:where any each any each' filter;
  :(key s)!{(key x)!(value x)@'where each y key x}[req] each value s&filter w;
  };
