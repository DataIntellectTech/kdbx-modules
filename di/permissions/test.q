/ mocks and helpers for di.permissions' tests. Helpers keep commas out of test.csv's code fields.

/ --- log: capturing, so tests can assert what init said ---
calls:([]lvl:`symbol$();ctx:`symbol$();msg:())
resetcalls:{[] `calls set ([]lvl:`symbol$();ctx:`symbol$();msg:()); }
mocklogfn:{[lvl;ctx;msg] `calls insert (lvl;ctx;msg); }
mocklog:{[] `info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;])}
logged:{[pat] 0<count select from calls where msg like pat}

/ --- handlers: record the registration, run nothing ---
reg:([]event:`symbol$();phase:`symbol$();nm:`symbol$())
resetreg:{[] `reg set ([]event:`symbol$();phase:`symbol$();nm:`symbol$()); }
mockreg:{[e;ph;n;p;f] `reg insert (e;ph;n); }
mockhandlers:{[] `register`remove`list!(mockreg;{[e;n]};{[e]()})}

mockdeps:{[] `log`handlers!(mocklog[];mockhandlers[])}
badlog:{[] enlist[`log]!enlist `info`warn!({[c;m]};{[c;m]})}

cfg:{[e] (enlist`enabled)!enlist e}
cfgwith:{[k;v] (`enabled`maxsize`runmode`permissivemode!(1b;200000000;1b;0b)),(enlist k)!enlist v}

/ which events got an exec owner
execevents:{[] asc exec event from reg where phase=`exec}
pcregistered:{[] 0<count select from reg where event=`.z.pc}

/ is a root name published
published:{[s] (last ` vs s) in key `.pm}
allpublished:{[names] all published each names}

/ the admin api, reached through the export rather than a root namespace
adminnames:{[] `adduser`removeuser`addgroup`removegroup`addrole`removerole`addtogroup,
  `removefromgroup`assignrole`unassignrole`addfunction`removefunction`grantaccess`revokeaccess,
  `grantfunction`revokefunction`createvirtualtable`removevirtualtable`addpublic`removepublic`cloneuser}
allexported:{[names] all names in key pm}

/ the only names di.torq.proc.gateway reads by symbol
gatewaynames:{[] `.pm.allowed`.pm.execas`.pm.val`.pm.valp}
/ nothing else should be in the .pm namespace
rootcount:{[] count (key `.pm) except `}

/ --- a ruleset, built through the root names exactly as a TorQ permissions file does ---
buildrules:{[]
  pm[`addrole][`admin;"full system access"];
  pm[`grantfunction][pm`ALL;`admin;{1b}];
  pm[`adduser][`alice;`local;`md5;md5"secret"];
  pm[`assignrole][`alice;`admin];
  pm[`addrole][`reader;"read only"];
  pm[`addgroup][`readers;"can read trade"];
  pm[`adduser][`bob;`local;`md5;md5"pass"];
  pm[`assignrole][`bob;`reader];
  pm[`addtogroup][`bob;`readers];
  pm[`grantaccess][`trade;`readers;`read];
  pm[`grantfunction][`select;`reader;{1b}];
  }

/ fixture tables at root, so variable-reference checks have something to resolve
setupfixture:{[]
  @[`.;`trade;:;([]sym:`a`b;px:1 2.0)];
  @[`.;`quote;:;([]sym:`a`b;bid:1 2.0)];
  }
teardownfixture:{[] @[`.;`trade;:;(::)]; @[`.;`quote;:;(::)]; }

/ check a user against a query string, without evaluating it
chk:{[u;q] pm[`allowed][u;parse q]}

/ a group that contains a group - TorQ chases the chain
buildnested:{[]
  pm[`addgroup][`seniors;"inherits readers"];
  pm[`adduser][`carol;`local;`md5;md5"pw"];
  pm[`assignrole][`carol;`reader];
  pm[`addtogroup][`carol;`seniors];
  pm[`addtogroup][`seniors;`readers];
  }

/ a virtual table enforcing a where clause
buildvirtual:{[]
  pm[`createvirtualtable][`vtrade;`trade;enlist (=;`sym;enlist `a)];
  pm[`grantaccess][`vtrade;`readers;`read];
  }

/ a dispatched payload whose function source is long enough for q to elide when stringified -
/ the shape di.asyncdispatch sends. Untrapped, lamq's -4! signals '[ on it. No reply leg, so it is
/ safe to evaluate with no peer handle.
elidedpayload:{[]
  f:{[rescb;errcb;qid;query] res:@[{(0b;value x)};query;{(1b;"server: ",x)}]; $[res 0;(errcb;qid;res 1);(rescb;qid;res 1)]};
  (f[`.gw.addserverresult;`.gw.addservererror];1;"select cnt:count i from trade")
  }

/ did requ complete without signalling
runsok:{[u;e] not `THREW~.[pm`requ;(u;e);{[err] `THREW}]}
