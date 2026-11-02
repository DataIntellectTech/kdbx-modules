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

/ a boolean setting - a boolean, a numeric atom or true/false/1/0; anything else errors
asbool:{[x]
  if[-1h=type x;:x];
  if[(type x) in -4 -5 -6 -7 -8 -9h;:0<>x];
  if[10h=abs type x;
    s:`$lower (),x;
    :$[s in `1`true;1b;
       s in `0`false;0b;
       '"di.util.cfg: cannot read \"",(string s),"\" as a boolean - use true or false"]];
  '"di.util.cfg: cannot read a value of type ",(string type x)," as a boolean - use true or false"
  }

/ a long setting - errors if it does not parse
aslong:{[x]
  r:$[-7h=type x;x;10h=abs type x;"J"$(),x;"j"$x];
  if[null r;'"di.util.cfg: cannot read \"",$[10h=abs type x;(),x;-3!x],"\" as a whole number"];
  r
  }

/ a timespan setting - a bare number is seconds, text is parsed
totimespan:{[x] $[-16h=type x;x;10h=abs type x;"N"$(),x;-11h=type x;"N"$string x;(type x) in -5 -6 -7h;0D00:00:01*x;0Nn]}

/ a symbol setting from text
tosym:{[x] $[(type x) in 0 10 -10h;`$x;x]}

/ an atom as a one-element list
aslist:{[x] $[0>type x;enlist x;x]}

/ a symbol or symbol list from text or symbols
assym:{[x] $[11h=abs type x;x;`$x]}

/ a token list from a space-separated string, a symbol or a symbol list
astoklist:{[x] $[10h=type x;`$" " vs x;-11h=type x;enlist x;11h=type x;x;`$x]}
