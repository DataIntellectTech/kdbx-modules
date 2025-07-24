/ Load helper scripts and run tests.

/ handlers we overwrite
.test.handlers:1!flip
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

.test.exusage:flip`id`zcmd`status`a`u`w`cmd`sz`error!"jscisi*j*"$\:();
.test.customtracker:flip`zcmd`args!"s*"$\:();
.test.wildcols:`time`extime`mem!12 16 0h;

.test.mocks:1!enlist`name`existed`orig!(`;0b;"");

.test.runhandler:{[handler;args]
  .test.id+:1;
  if[b:handler~`.z.ws;.test.mock[`.z.ps;{}]]; / swallow websocket response
  res:$[`.z.pw~handler;.;@][handler;args];
  if[b;.test.unmock`.z.ps];
  typ:.test.handlers[handler;`typ];
  .test[typ][last` vs handler;args;res];
  };

.test.auth:{[zcmd;args;res]
  .test.exusage,:(.test.id;zcmd;"c";.z.a;.z.u;0i;.usage.formatarg[zcmd;(first args;"***")];0N;"");
  };

.test.conn:{[zcmd;args;res]
  .test.exusage,:(.test.id;zcmd;"c";.z.a;.z.u;0i;.usage.formatarg[zcmd;args];0N;"");
  };

.test.query:{[zcmd;args;res]
  rows:([]
    id:.test.id;
    zcmd;
    status:"bc";
    a:.z.a;
    u:.z.u;
    w:0i;
    cmd:.usage.formatarg[zcmd;]each(args;args);
    sz:0N,-22!res;
    error:("";""));
  .test.exusage,:rows;
  };

.test.chkusage:{[tbl]
  usg:$[tbl~(::);.usage.usage;tbl];

  // wild columns -- we know the type but can't accurately predict the value
  if[not type'[.usage.usage key .test.wildcols]~value .test.wildcols;:0b];

  // other columns should match our expectations exactly
  .test.exusage~key[flip .test.exusage]#.usage.usage
  };

.test.mock:{[name;mockval]
  if[not name in key .test.mocks;
    .test.mocks[name;`existed`orig]:@[{(1b;get x)};name;{(0b;::)}]];
  name set mockval;
  };

.test.unmock:{[nm]
  if[1=count .test.mocks;:()]; / only sentinel row
  t:0!$[nm~(::);1_.test.mocks;select from .test.mocks where name in nm];
  .test.deletefromns each exec name from t where not existed;
  exec name set'orig from .test.mocks where existed;
  .test.mocks:(select name from t)_.test.mocks;
  };

.test.deletefromns:{[obj]
  if[obj like".z.*";:system"x ",string obj]; / Special .z callbacks
  split:` vs obj;
  k:last obj;
  ns:$[1=count split;`.;` sv -1_split];
  ![ns;();0b;enlist k];
  }

.test.reset:{[]
  .test.unmock[];
  .test.wipehandlers[];
  .usage.usage:0#.usage.usage;
  .test.exusage:0#.test.exusage;
  .test.customtracker:1#.test.customtracker;
  };

.test.wipehandlers:{[]
  b:(t:0!.test.handlers)[`default]~\:(::);
  system each"x ",/:string t[where b;`name];
  exec name set'default from t where not b;
  };

.test.setcustomhandlers:{[]
  exec name set'{('[x y;enlist])}[.test.customhandler;]each name from .test.handlers;
  }

.test.customhandler:{[zcmd;args]
  .test.customtracker,:(zcmd;$[1=count args;first;]args);
  };

/ run tests

\l ../usage.q
\l k4unit.q
.lg.o:{[x;y] -1 .Q.s1(.z.P;x;y);};
.lg.e:{[x;y] -2 .Q.s1(.z.P;x;y);};
.proc.stop:0b
KUltf`:tests.csv;
KUrt[];
show KUTR;
show "#####################################";
show " Failed Tests";
show select from KUTR where not ok;
show "#####################################";
