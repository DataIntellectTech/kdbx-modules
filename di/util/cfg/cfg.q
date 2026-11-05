/ config resolution helpers shared by di.* modules - path roots and value coercion

/ app code and config root
apphome:{[] getenv[`TORQXAPPHOME]}

/ runtime data root, falling back to the app root when unset
datahome:{[] $[count h:getenv[`TORQXDATAHOME];h;getenv[`TORQXAPPHOME]]}

/ resolve a relative path setting to an absolute path string under base
resolvedir:{[base;dir]
  dir:$[10h=abs type dir;(),dir;string dir];
  dir:$[(0<count dir) and ":"=first dir;1_dir;dir];
  $[dir like "/*";dir;base,"/",dir]
  }

/ a boolean setting - a boolean, a numeric atom or true/false, yes/no, t/f, y/n, 1/0; anything else errors
asbool:{[x]
  if[-1h=type x;:x];
  if[(type x) in -4 -5 -6 -7 -8 -9h;
    if[null x;'"di.util.cfg: cannot read a null as a boolean - use true or false"];
    :0<>x];
  if[10h=abs type x;
    s:`$lower (),x;
    :$[s in `true`yes`t`y`1;1b;
       s in `false`no`f`n`0;0b;
       '"di.util.cfg: cannot read \"",(string s),"\" as a boolean - use true or false"]];
  '"di.util.cfg: cannot read a value of type ",(string type x)," as a boolean - use true or false"
  }

/ a long setting - errors if it does not parse
aslong:{[x]
  r:$[-7h=type x;x;10h=abs type x;"J"$(),x;"j"$x];
  if[null r;'"di.util.cfg: cannot read \"",$[10h=abs type x;(),x;-3!x],"\" as a whole number"];
  r
  }

/ what a bare number counts in, for astimespan
spanunits:`second`minute`hour!0D00:00:01 0D00:01 0D01;

/ a number scaled by unit: infinity stays infinite, null if too big for a timespan
scale:{[u;x]
  inf:$[-5h=t:type x;0Wh;-6h=t;0Wi;-7h=t;0W;0w];
  if[inf=abs x;:$[x<0;-0Wn;0Wn]];
  f:(`float$u)*`float$x;
  if[9.2e18<abs f;:0Nn];
  $[t in -8 -9h;`timespan$f;u*x]
  }

/ a timespan setting - a bare number (or bare digits as text) counts in unit; anything unreadable errors
astimespan:{[unit;x]
  if[null u:spanunits unit;'"di.util.cfg: astimespan unit must be one of ",", " sv string key spanunits];
  x:$[-11h=type x;string x;x];
  r:$[-16h=type x;x;
      (type x) in -17 -18 -19h;`timespan$x;
      (type x) in -5 -6 -7 -8 -9h;scale[u;x];
      10h=abs type x;$[any ((),x) in "D:";"N"$(),x;scale[u;"F"$(),x]];
      0Nn];
  if[null r;'"di.util.cfg: cannot read \"",$[10h=abs type x;(),x;-3!x],"\" as a timespan"];
  r
  }

/ run a coercion on a setting, naming the setting if it fails
named:{[k;f;x] @[f;x;{[k;e] '"setting ",(string k),": ",e}[k]]}

/ an atom as a one-element list
aslist:{[x] $[0>type x;enlist x;x]}

/ a symbol or symbol list from text or symbols
assym:{[x] $[11h=abs type x;x;`$x]}

/ a token list from a space-separated string, a symbol or a symbol list
astoklist:{[x] $[10h=type x;`$" " vs x;-11h=type x;enlist x;11h=type x;x;`$x]}
