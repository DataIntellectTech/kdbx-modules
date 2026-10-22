/ di.permissions - client access control (users, groups, roles, virtual tables)

\l ::permissions.q

version:first read0`:::VERSION

/ the admin api is exported, not published into a root namespace - the rule files that populate
/ the schema reach it through `use`. Only the four names di.torq.proc.gateway reads by symbol are
/ published at root (see publishroot).
export:([init;getapimeta;version;ALL;
  adduser;removeuser;addgroup;removegroup;addrole;removerole;addtogroup;removefromgroup;
  assignrole;unassignrole;addfunction;removefunction;grantaccess;revokeaccess;grantfunction;
  revokefunction;createvirtualtable;removevirtualtable;addpublic;removepublic;cloneuser;
  allowed;cando;requ;req;execas;login])
