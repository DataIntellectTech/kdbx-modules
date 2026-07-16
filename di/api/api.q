/ api - registration and metadata for a process's public API functions
/ each entry describes one callable function: its name, whether it is public, and human-readable
/ description / parameters / return text. the registry is the single source of truth (there is no
/ live-namespace scan - module code is not in scannable root namespaces).
/ registration model: di.torq collects the api metadata from each module at startup and registers
/ it here centrally via add. di.api itself has no dependency on other modules.
/ public api: add (register an entry), getapi (whole registry), find/f/p (query by name + public).

/ empty template for the registry (constant); .z.m.detail is the live, mutable copy
detailschema:([name:`u#`symbol$()] public:`boolean$(); descrip:(); params:(); return:());

init:{[deps]
  / wire the injected logger (required, no fallback) and start with an empty registry.
  / deps: a dict with a `log key holding a binary `info`warn`error dict of {[c;m]} loggers
  / (from di.log or hand-rolled); no adaptation, so a monadic kx.log instance must be wrapped
  / first. e.g. di.api.init[enlist[`log]!enlist logdep]
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
  / register (or overwrite) one api entry describing a callable function. keyed on name, so
  / re-adding the same name updates it in place. typically called by di.torq at startup for
  / each module's exported functions.
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
  / return the full registry of api entries as a keyed table (keyed on name)
  :.z.m.detail;
  };

find:{[s;p]
  / return registry entries whose name matches pattern s and whose public flag is in p.
  / s: a symbol (` matches everything, otherwise matched as a *s* substring) or a string glob.
  / p: a boolean (or list) of public flags to include - 1b public-only, 01b all.
  / name matching is case-insensitive. returns an (unkeyed) table of matching entries.
  if[-11h=type s;s:$[null s;"*";"*",string[s],"*"]];
  if[not 10h=abs type s:s,();
    .z.m.logerr[`find;err:"di.api: search pattern must be a symbol or string"];
    'err;
  ];
  :select from .z.m.detail where lower[string name] like lower s, public in p;
  };

/ find all entries (public and non-public)
f:find[;01b];
/ find public entries only
p:find[;1b];
