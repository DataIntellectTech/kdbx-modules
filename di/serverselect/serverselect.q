/ library for selecting backend servers from a registered pool based on servertype or attribute requirements

/ registered server pool - populated by addserverattr
servers:([serverid:`u#`int$()] handle:`int$(); servertype:`symbol$(); active:`boolean$(); attributes:());

/ autoincrement counter for server IDs
serverid:0i;

init:{[deps]
  / wire injectable log dependency (required)
  logdict:$[99h=type deps;
    $[`log in key deps;
      $[99h=type deps`log; deps`log; ()!()];
      ()!()];
    ()!()];
  if[not count logdict;
    '"di.serverselect: log dependency is required; pass `info`warn`error functions - ",
     "see di.log for a default implementation or refer to confluence documentation";
  ];
  if[not all (`info`warn`error) in key logdict;
    '"di.serverselect: log dict must have `info`warn`error keys; got: ",(", " sv string key logdict);
  ];
  .z.m.loginfo:logdict`info;
  .z.m.logwarn:logdict`warn;
  .z.m.logerr:logdict`error;
  };

/ internal - increment and return the next unique server ID
nextserverid:{
  .z.m.serverid:serverid+1i;
  :.z.m.serverid;
  };

addserverattr:{[h;st;att]
  / register a server handle with a servertype and attribute dictionary
  .z.m.loginfo[`addserverattr;"registering server: handle=",(string h),", type=",string st];
  .z.m.servers:servers upsert (nextserverid[];h;st;1b;att);
  };

addserver:{[h;st]
  / register a server with no attributes; convenience wrapper over addserverattr
  addserverattr[h;st;()!()];
  };

setserveractive:{[h;a]
  / mark a registered server active (1b) or inactive (0b); called on connect and disconnect
  .z.m.loginfo[`setserveractive;"marking handle=",(string h)," active=",string a];
  .z.m.servers:update active:a from servers where handle=h;
  };

getservers:{[]
  / return the current registered server table
  :servers;
  };

addserversfromtable:{[proctypes;conntable]
  / register active servers from a connection table filtered by proctype
  / conntable must have columns: w (int handle), proctype (symbol), attributes (dict per row)
  / pass proctypes:`ALL to register all process types
  activehandles:(0i;0Ni),exec handle from servers where active;
  rows:select w,proctype,attributes from conntable where
    ((proctype in proctypes) or proctypes~`ALL),
    not w in activehandles;
  .z.m.loginfo[`addserversfromtable;"registering ",(string count rows)," servers from connection table"];
  addserverattr'[rows`w;rows`proctype;rows`attributes];
  };

getserverids:{[att]
  / return server IDs matching a servertype list or attribute requirement dictionary
  / att: symbol list of servertypes, or dict of attribute requirements (optionally keyed on `servertype)
  if[99h<>type att;
    if[not 11h=abs type att;
      '"di.serverselect: servertype must be a symbol list (11h) or attribute dict (99h)";
    ];
    servertype:distinct att,();
    activeservers:exec distinct servertype from servers where active;
    allservers:exec distinct servertype from servers;
    activeserversmsg:". available servers: ",", " sv string activeservers;
    if[any null att;
      '"di.serverselect: null servertype passed as argument",activeserversmsg;
    ];
    if[count servertype except activeservers;
      '"di.serverselect: ",
        $[max not servertype in allservers;
          "not valid servers: ",", " sv string servertype except allservers;
          "requested servers currently inactive: ",", " sv string servertype except activeservers
        ],activeserversmsg;
    ];
    :(exec serverid by servertype from servers where active)[servertype];
  ];
  serverids:$[`servertype in key att;
    raze getserveridstype[delete servertype from att] each (),att`servertype;
    getserveridstype[att;`all]];
  if[all 0=count each serverids;'"di.serverselect: no servers match requested attributes"];
  :serverids;
  };

/ internal - filter active servers by servertype and attribute requirements
getserveridstype:{[att;typ]
  / resolve besteffort and attributetype control keys then dispatch to cross or independent matching
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
  if[all 0=count each serverids;'"di.serverselect: no servers match ",string[typ]," requested attributes"];
  :serverids;
  };

/ internal - build a cross product table from a nested dictionary
buildcross:{(cross/){flip (enlist y)#x}[x] each key x};

/ internal - initial filter shared by cross and independent matching
/ drops servers missing any required attribute key, ranks survivors by coverage
getserversinitial:{[req;att]
  if[0=count req; :([]serverid:enlist key att)];
  att:(where all each (key req) in/: key each att)#att;
  if[not count att;'"di.serverselect: no servers report all requested attributes"];
  s:update serverid:key att from value req in'/: (key req)#/:att;
  s:s idesc value min each sum each' `serverid xkey s;
  s:`serverid xkey 0!(key req) xgroup s;
  :s;
  };

/ internal - find servers satisfying the cross product of all attribute requirements
/ each attribute combination must be coverable by a single server
getserverscross:{[req;att;besteffort]
  if[0=count req; :([]serverid:enlist key att)];
  s:getserversinitial[req;att];
  reqcross:buildcross[req];
  / scan through each server group accumulating which cross-product rows have been covered
  util:flip `remaining`found!flip (
    {[x;y;z] (y[0] except found; y[0] inter found:$[0=count y[0];y[0];buildcross x@'where each z])}[req]\
    )[(reqcross;());value s];
  if[(count last util`remaining) and not besteffort;
    '"di.serverselect: cannot satisfy query - cross product of all attributes cannot be matched";
  ];
  s:1!(0!s) w:where not 0=count each util`found;
  :(key s)!distinct each' flip each util[w]`found;
  };

/ internal - find servers satisfying attribute requirements independently
/ each individual requirement only needs to be matched by one server
getserversindependent:{[req;att;besteffort]
  if[0=count req; :([]serverid:enlist key att)];
  s:getserversinitial[req;att];
  / mask out server groups whose contribution is already covered by earlier groups
  filter:(value s)&not -1 _ (0b&(value s) enlist 0),maxs value s;
  alldone:1+first where all each all each' maxs value s;
  if[(null alldone) and not besteffort;
    '"di.serverselect: cannot satisfy query - not all attributes can be matched";
  ];
  s:1!(0!s) w:where any each any each' filter;
  :(key s)!{(key x)!(value x)@'where each y key x}[req] each value s&filter w;
  };
