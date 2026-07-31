/ minimal built-in HDB process module. No di.sort dependency yet (real plan lists
/ it as a hard dep for attribute re-application) - flagged as a v1 gap.

/ resolve a possibly-relative dir symbol to an absolute one, joined against TORQXDATAHOME
/ (where runtime DATA lives - the hdb is data, not code/config; TORQXDATAHOME falls back to
/ TORQXAPPHOME when unset, fine for a sample app where they coincide).
/ avoids cwd-sensitivity when reload[] is triggered remotely rather than called locally.
/ dir may arrive as a symbol (.q settings, e.g. dir:`:hdb) or a plain string (.toml
/ settings, since TOML has no symbol type - di.torq.config's TOML integration is
/ policy-free, see di/torq/config/config.q). Normalized to a symbol immediately, once,
/ so `string`/`1_string` below (and .z.m.dir downstream in init/reload) never have
/ to worry about which format it came from - `$ is a no-op on an already-symbol
/ input's contents but NOT idempotent syntactically (`$ on a symbol atom throws
/ 'type), hence the type check rather than an unconditional cast.
datahome:{$[count h:getenv[`TORQXDATAHOME];h;getenv[`TORQXAPPHOME]]}
resolvedir:{[dir]
  dir:$[11h=abs type dir;dir;`$dir];
  s:1_string dir;
  $[s like "/*";dir;`$":",datahome[],"/",s]
  }

init:{[config;deps]
  if[not `log in key deps;'"di.proc.hdb: log dependency is required - see di.util.log"];
  .z.m.log:deps`log;
  .z.m.dir:resolvedir config`dir;
  .z.m.log[`info][`hdb;"mounting hdb from ",string .z.m.dir];
  system "l ",1_string .z.m.dir;
  .z.m.log[`info][`hdb;"loaded tables: ",", " sv string tables[]];
  / publish the IPC-callable surface at a real root-level name - use`di.proc.hdb loads this
  / file into a private namespace (.m.di.0hdb.*), so a remote `.hdb.reload[]` call would
  / otherwise hit an undefined-function error. Matches TorQ's own convention of putting
  / IPC entry points like endofday/reload at root (torq-developer skill, Rule E3).
  set[`.hdb.reload;reload];
  }

reload:{[]
  .z.m.log[`info][`hdb;"reloading hdb from ",string .z.m.dir];
  system "l ",1_string .z.m.dir;
  }
