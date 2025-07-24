/ load helper scripts and run tests.

/ handlers we overwrite, columns are
/ name    {sym} handler name
/ typ     {sym} type of handler, corresponds to a function in the `.testusg` namespace
/ default {fn}  default kdb implementation where `(::)` means there is none
.testusg.handlers:1!flip
  (`name;     `typ;   `default)!flip(
  (`.z.pw;    `auth;  ::);
  (`.z.po;    `conn;  ::);
  (`.z.pc;    `conn;  ::);
  (`.z.wo;    `conn;  ::);
  (`.z.wc;    `conn;  ::);
  (`.z.ws;    `query; ::);
  (`.z.pg;    `query; ::);
  (`.z.ps;    `query; ::);
  (`.z.ph;    `query; .z.ph);
  (`.z.pp;    `query; ::);
  (`.z.exit;  `query; ::));

/ internal tables/metadata we use to facilitate testing
.testusg.exusage:flip`id`zcmd`status`a`u`w`cmd`sz`error!"jscisi*j*"$\:(); / same schema as `.usage.usage`
.testusg.customtracker:enlist`zcmd`args!(`;""); / keeps track of invocation
.testusg.wildcols:`time`extime`mem!12 16 0h; / `.usage.usage` columns we can't accurately predict

/ runs a handler and keeps track of it internally so we can validate it against the usage table afterwards
/ param handler {sym} handler, e.g. `.z.ps`
/ param args    {any} args to handler
.testusg.runhandler:{[handler;args]
  .testusg.id+:1;
  if[b:handler~`.z.ws;.test.mock[`.z.ps;{}]]; / swallow websocket response
  res:$[`.z.pw~handler;.;@][handler;args];
  if[b;.test.unmock`.z.ps];
  typ:.testusg.handlers[handler;`typ];
  .testusg[typ][last` vs handler;args;res];
  };

/ appends auth-type calls to `.testusg.exusage`
/ param zcmd  {sym}           .z handler, `pw` is currently the only one
/ param args  {(sym;string)}  in theory could be anything, but since it's only `.z.pw`, it's `(user;password)`
/ param res   {any}           result of the call, which is ignored
.testusg.auth:{[zcmd;args;res]
  .testusg.exusage,:(.testusg.id;zcmd;"c";.z.a;.z.u;0i;.usage.formatarg[zcmd;(first args;"***")];0N;"");
  };

/ appends conn-type calls to `.testusg.exusage`
/ param zcmd  {sym} .z handler
/ param args  {int} in theory could be anything, but all connection handlers take a handle
/ param res   {any} result of the call, which is ignored
.testusg.conn:{[zcmd;args;res]
  .testusg.exusage,:(.testusg.id;zcmd;"c";.z.a;.z.u;0i;.usage.formatarg[zcmd;args];0N;"");
  };

/ appends conn-type calls to `.testusg.exusage`
/ param zcmd  {sym} .z handler
/ param args  {any} input to the .z handler
/ param res   {any} result of the call
.testusg.query:{[zcmd;args;res]
  rows:([]
    id:.testusg.id;
    zcmd;
    status:"bc";
    a:.z.a;
    u:.z.u;
    w:0i;
    cmd:.usage.formatarg[zcmd;]each(args;args);
    sz:0N,-22!res;
    error:("";""));
  .testusg.exusage,:rows;
  };

/ checks that the `.testusg.exusage` table matches the specified table
/ param tbl {table|::}  table to verify again, if null we check against `.usage.usage`
/ return    {bool}      true if we have a match, false otherwise
.testusg.chkusage:{[tbl]
  usg:$[tbl~(::);.usage.usage;tbl];

  // wild columns -- we know the type but can't accurately predict the value
  if[not type'[.usage.usage key .testusg.wildcols]~value .testusg.wildcols;:0b];

  // other columns should match our expectations exactly
  .testusg.exusage~key[flip .testusg.exusage]#.usage.usage
  };

/ resets all internal variable, must call `.usage.init` afterwards
.testusg.reset:{[]
  .testusg.wipehandlers[];
  .usage.usage:0#.usage.usage;
  .testusg.exusage:0#.testusg.exusage;
  .testusg.customtracker:1#.testusg.customtracker;
  };

/ wipes all handler definitions
.testusg.wipehandlers:{[]
  b:(t:0!.testusg.handlers)[`default]~\:(::);
  system each"x ",/:string t[where b;`name];
  exec name set'default from t where not b;
  };

/ sets all handlers in `.testusg.handler` to custom functions to override the defaults
/ we set the handlers to a projection of `.testusg.customhandler`
.testusg.setcustomhandlers:{[]
  exec name set'{('[x y;enlist])}[.testusg.customhandler;]each name from .testusg.handlers;
  }

/ custom handler, which logs calls to `.testusg.customtracker`
.testusg.customhandler:{[zcmd;args]
  .testusg.customtracker,:(zcmd;$[1=count args;first;]args);
  };
