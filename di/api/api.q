/ api - a registry of a process's callable functions: one entry per function holding its name,
/ public flag, and description / params / return text. registry-only (no live namespace scan -
/ module code is not in root namespaces). di.torq registers each module's metadata here via add;
/ di.api depends on no other module. public api: add, getapi, find/f/p.

/ registry template (constant); .z.m.detail is the live copy
detailschema:([name:`u#`symbol$()] public:`boolean$(); descrip:(); params:(); return:());

init:{[deps]
  / wire the injected logger (required, no fallback) and start with an empty registry. deps: a `log
  / key holding a binary `info`warn`error dict of {[c;m]} loggers (di.log or hand-rolled; a monadic
  / kx.log instance must be wrapped first). e.g. di.api.init[enlist[`log]!enlist logdep]
  if[99h<>type deps;
    '"di.api: deps must be a dict with a `log key"];
  if[not `log in key deps;
    '"di.api: log dependency is required; pass `info`warn`error functions keyed on `log"];
  if[99h<>type deps`log;
    '"di.api: log value must be a dict of `info`warn`error functions"];
  if[not all (`info`warn`error) in key deps`log;
    '"di.api: log dict must have `info`warn`error keys; got: ",(", " sv string key deps`log)];
  .z.m.loginfo:deps[`log]`info;
  .z.m.logwarn:deps[`log]`warn;
  .z.m.logerr:deps[`log]`error;
  .z.m.detail:detailschema;
  };

add:{[name;public;descrip;params;return]
  / register (or overwrite) one entry, keyed on name (re-adding a name updates in place).
  / called by di.torq at startup for each module's exported functions.
  if[not -11h=type name;
    .z.m.logerr[`add;err:"di.api: name must be a symbol"];
    'err;
  ];
  if[not -1h=type public;
    .z.m.logerr[`add;err:"di.api: public must be a boolean"];
    'err;
  ];
  .z.m.detail:.z.m.detail upsert (name;public;descrip;params;return);
  };

getapi:{[]
  / return the whole registry (keyed table, keyed on name)
  :.z.m.detail;
  };

find:{[s;p]
  / registry entries whose name matches s and whose public flag is in p. s: a symbol (` = all, else
  / a *s* substring) or a string glob; p: public flags to include (1b public-only, 01b all).
  / case-insensitive; returns an unkeyed table.
  if[-11h=type s;s:$[null s;"*";"*",string[s],"*"]];
  if[not 10h=abs type s:s,();
    .z.m.logerr[`find;err:"di.api: search pattern must be a symbol or string"];
    'err;
  ];
  :select from .z.m.detail where lower[string name] like lower s, public in p;
  };

/ all entries (public and non-public)
f:find[;01b];
/ public entries only
p:find[;1b];

getapimeta:{[]
  / this module's api metadata, one row per exported function, for di.torq to collect and register
  / with di.api. names are bare (the module's own); di.torq applies the process-wide qualification.
  :([]
    name:`init`add`getapi`find`f`p`getapimeta;
    public:0011110b;
    descrip:(
      "wire the injected logger and start an empty registry";
      "register (or overwrite) one api entry, keyed on name";
      "return the whole registry (keyed table)";
      "registry entries matching a name pattern and public flag";
      "find[;01b] - all entries matching a name pattern";
      "find[;1b] - public entries matching a name pattern";
      "this module's api metadata rows");
    params:(
      "[dict: deps with a `log key]";
      "[symbol: name; boolean: public; descrip; params; return]";
      "[]";
      "[symbol|string: name pattern; boolean(list): public flags]";
      "[symbol|string: name pattern]";
      "[symbol|string: name pattern]";
      "[]");
    return:(
      "null";
      "null";
      "keyed table: the registry";
      "table: matching entries";
      "table: matching entries";
      "table: matching public entries";
      "table: metadata rows"));
  };
