/ di.clienttracking - track client sessions in .clients.clients

init:{[config;deps]
  if[not `handlers in key deps;'"di.clienttracking: handlers dependency is required - see di.torq.handlers"];
  / all settings required
  req:`clients_enabled`clients_opencloseonly`clients_intrusive`clients_autoclean`clients_retain`clients_maxidle;
  if[count m:req except key config;'"di.clienttracking: missing settings: ",", " sv string m];
  .z.m.enabled:config`clients_enabled;
  .z.m.opencloseonly:config`clients_opencloseonly;
  .z.m.intrusive:config`clients_intrusive;
  .z.m.autoclean:config`clients_autoclean;
  .z.m.retain:config`clients_retain;
  .z.m.maxidle:config`clients_maxidle;
  r:deps[`handlers]`register;
  r[`.z.pc;`;`clients;0j;pc[::;]];
  if[enabled;
    r[`.z.po;`;`clients;0j;po[::;]];
    r[`.z.wo;`;`clients;0j;wo[::;]];
    r[`.z.wc;`;`clients;0j;pc[::;]];
    if[not opencloseonly;
      set[`.z.pg;{hit[@[x;y;hite]]}@[value;`.z.pg;{.:}]];
      set[`.z.ps;{hit[@[x;y;hite]]}@[value;`.z.ps;{.:}]];
      set[`.z.ws;{hit[@[x;y;hite]]}@[value;`.z.ws;{{neg[.z.w]x;}}]]]];
  }

IPA:(.z.a,.Q.addr`localhost)!.z.h,`localhost;
ipa:{$[`~r:IPA x;.z.m.IPA[x]:$[`~r:.Q.host x;`$"."sv string"i"$0x0 vs x;r];r]};
livehx:{y in x,key .z.W};
/ live-handle checks, shared with di.torq.servers
if[not `liveh in key `.dotz;
    .dotz.liveh:livehx(); .dotz.livehn:livehx 0Ni; .dotz.liveh0:livehx 0i];

/ root: queried remotely
.clients.clients:@[value;`.clients.clients;([w:`int$()]ipa:`symbol$();u:`symbol$();a:`int$();k:`date$();K:`float$();c:`int$();s:`int$();o:`symbol$();f:`symbol$();pid:`int$();port:`int$();startp:`timestamp$();endp:`timestamp$();lastp:`timestamp$();hits:`int$();errs:`int$();sz:`long$())];

unregistered:{except[key .z.W;exec w from`CLIENTS]}
cleanup:{
    if[count w0:exec w from`.clients.clients where not .dotz.livehn w;
        update endp:.z.p,w:0Ni from`.clients.clients where w in w0];
    if[maxidle>0;
        hclose each exec w from`.clients.clients where .dotz.liveh w,lastp<.z.p-.z.m.maxidle];
    delete from`.clients.clients where not .dotz.liveh w,endp<.z.p-.z.m.retain;}
hit:{update lastp:.z.p,hits:hits+1i,sz:sz+-22!x from`.clients.clients where w=.z.w;x}
hite:{update lastp:.z.p,hits:hits+1i,errs:errs+1i from`.clients.clients where w=.z.w;'x}
po:{[result;W]
    cleanup[];
    `.clients.clients upsert(W;ipa .z.a;.z.u;.z.a;0Nd;0n;0Ni;0Ni;(`);(`);0Ni;0Ni;zp;0Np;zp:.z.p;0i;0i;0j);
    if[intrusive;
        neg[W]"neg[.z.w]\"update k:\",(string .z.k),\",K:\",(-3!.z.K),\",c:\",(-3!.z.c),\",s:\",(-3!system\"s\"),\",o:\",(-3!.z.o),\",f:\",(-3!.z.f),\",pid:\",(-3!.z.i),\",port:\",(-3!system\"p\"),\" from`.clients.clients where w=.z.w\""];
    result}
addw:{po[x;x]}
pc:{[result;W] update w:0Ni,endp:.z.p from`.clients.clients where w=W;cleanup[];result}

wo:{[result;W]
    cleanup[];
    `.clients.clients upsert(W;ipa .z.a;.z.u;.z.a;0Nd;0n;0Ni;0Ni;(`);(`);0Ni;0Ni;zp;0Np;zp:.z.p;0i;0i;0j);
    result}
