/ di.torq.proc.hdb - mounts an hdb directory and reloads it

/ resolve dir (symbol or string) to an absolute file symbol; a relative dir joins TORQXDATAHOME, else TORQXAPPHOME
datahome:{$[count h:getenv[`TORQXDATAHOME];h;getenv[`TORQXAPPHOME]]}
resolvedir:{[dir]
  dir:$[11h=abs type dir;dir;`$dir];
  s:1_string dir;
  $[s like "/*";dir;`$":",datahome[],"/",s]
  }

init:{[config;deps]
  if[not `log in key deps;'"di.torq.proc.hdb: log dependency is required - see di.util.log"];
  .z.m.log:deps`log;
  .z.m.dir:resolvedir config`dir;
  .z.m.log[`info][`hdb;"mounting hdb from ",string .z.m.dir];
  system "l ",1_string .z.m.dir;
  .z.m.log[`info][`hdb;"loaded tables: ",", " sv string tables[]];
  / publish reload at root for IPC callers
  set[`.hdb.reload;reload];
  }

reload:{[]
  .z.m.log[`info][`hdb;"reloading hdb from ",string .z.m.dir];
  system "l ",1_string .z.m.dir;
  }
