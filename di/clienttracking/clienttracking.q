/ di.clienttracking - track client sessions in .clients.clients

init:{[config;deps]
  if[not `handlers in key deps;'"di.clienttracking: handlers dependency is required - see di.torq.handlers"];
  {[s;k] set[` sv `.clients,k;s k]}[s] each key s:$[`clients in key config;config`clients;()!()];
  r:deps[`handlers]`register;
  r[`.z.pc;`;`clients;0j;.clients.pc[::;]];
  if[.clients.enabled;
    r[`.z.po;`;`clients;0j;.clients.po[::;]];
    r[`.z.wo;`;`clients;0j;.clients.wo[::;]];
    r[`.z.wc;`;`clients;0j;.clients.pc[::;]];
    if[not .clients.opencloseonly;
      set[`.z.pg;{.clients.hit[@[x;y;.clients.hite]]}@[value;`.z.pg;{.:}]];
      set[`.z.ps;{.clients.hit[@[x;y;.clients.hite]]}@[value;`.z.ps;{.:}]];
      set[`.z.ws;{.clients.hit[@[x;y;.clients.hite]]}@[value;`.z.ws;{{neg[.z.w]x;}}]]]];
  }

\d .dotz

if[not `IPA in key `.dotz;
    IPA:(.z.a,.Q.addr`localhost)!.z.h,`localhost;
    ipa:{$[`~r:IPA x;IPA[x]:$[`~r:.Q.host x;`$"."sv string"i"$0x0 vs x;r];r]}];
if[not `liveh in key `.dotz;
    livehx:{y in x,key .z.W}; liveh:livehx(); livehn:livehx 0Ni; liveh0:livehx 0i];

\d .clients

/ settings
enabled:1b
opencloseonly:0b
INTRUSIVE:0b
AUTOCLEAN:1b
RETAIN:`long$0D02
MAXIDLE:`long$0D

enabled:@[value;`enabled;1b]
opencloseonly:@[value;`opencloseonly;0b]

clients:@[value;`clients;([w:`int$()]ipa:`symbol$();u:`symbol$();a:`int$();k:`date$();K:`float$();c:`int$();s:`int$();o:`symbol$();f:`symbol$();pid:`int$();port:`int$();startp:`timestamp$();endp:`timestamp$();lastp:`timestamp$();hits:`int$();errs:`int$();sz:`long$())]

unregistered:{except[key .z.W;exec w from`CLIENTS]}
cleanup:{
    if[count w0:exec w from`.clients.clients where not .dotz.livehn w;
        update endp:.z.p,w:0Ni from`.clients.clients where w in w0];
    if[.clients.MAXIDLE>0;
        hclose each exec w from`.clients.clients where .dotz.liveh w,lastp<.z.p-.clients.MAXIDLE];
    delete from`.clients.clients where not .dotz.liveh w,endp<.z.p-.clients.RETAIN;}
hit:{update lastp:.z.p,hits:hits+1i,sz:sz+-22!x from`.clients.clients where w=.z.w;x}
hite:{update lastp:.z.p,hits:hits+1i,errs:errs+1i from`.clients.clients where w=.z.w;'x}
po:{[result;W]
    cleanup[];
    `.clients.clients upsert(W;.dotz.ipa .z.a;.z.u;.z.a;0Nd;0n;0Ni;0Ni;(`);(`);0Ni;0Ni;zp;0Np;zp:.z.p;0i;0i;0j);
    if[INTRUSIVE;
        neg[W]"neg[.z.w]\"update k:\",(string .z.k),\",K:\",(-3!.z.K),\",c:\",(-3!.z.c),\",s:\",(-3!system\"s\"),\",o:\",(-3!.z.o),\",f:\",(-3!.z.f),\",pid:\",(-3!.z.i),\",port:\",(-3!system\"p\"),\" from`.clients.clients where w=.z.w\""];
    result}
addw:{po[x;x]}
pc:{[result;W] update w:0Ni,endp:.z.p from`.clients.clients where w=W;cleanup[];result}

wo:{[result;W]
    cleanup[];
    `.clients.clients upsert(W;.dotz.ipa .z.a;.z.u;.z.a;0Nd;0n;0Ni;0Ni;(`);(`);0Ni;0Ni;zp;0Np;zp:.z.p;0i;0i;0j);
    result}

\d .
