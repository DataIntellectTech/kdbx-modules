/ log file metadata: logs opened, tables feeding each, message counts

\d .stpm

metatable:([]seq:`int$();logname:`$();start:`timestamp$();end:`timestamp$();tbls:();msgcount:`int$();schema:();additional:())

/ meta update per logging mode, run on log open and close
updmeta:enlist[`]!enlist ()

updmeta[`tabperiod]:{[x;t;p]
  getmeta[x;p;;]'[enlist each t;`..currlog[([]tbl:t)]`logname];
  setmeta[.stplg.dldir;metatable];
 };

updmeta[`singular]:{[x;t;p]
  getmeta[x;p;t;`..currlog[first t]`logname];
  setmeta[.stplg.dldir;metatable];
 };

updmeta[`periodic]:updmeta[`singular]

updmeta[`tabular]:updmeta[`tabperiod]

updmeta[`custom]:{[x;t;p]
  pertabs:where `periodic=.stplg.custommode;
  updmeta[`periodic][x;t inter pertabs;p];
  updmeta[`tabular][x;t except pertabs;p]
 };

/ name, start, tables and schema on open; end and message count on close
getmeta:{[x;p;t;ln]
  if[x~`open;
    s:((),t)!(),.stpps.schemas[t];
    `.stpm.metatable upsert (.stplg.i;ln;p;0Np;t;0;s;enlist ()!());
  ];
  if[x~`close;
    update end:p,msgcount:sum .stplg.msgcount[t] from `.stpm.metatable where logname = ln
  ]
 };

setmeta:{[dir;mt]
  t:(hsym`$string[dir],"/stpmeta");
  .[{x set y};(t;mt);{.z.m.log[`error][`setmeta;"Failed to set metatable with error: ",x]}];
 };
