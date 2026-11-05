/ TOML subset parser to a q dict: bare or "quoted" keys, # comments, one level of [section], and
/ strings, longs, floats, booleans and flat arrays; anything else signals; no init or deps

keychars:.Q.a,.Q.A,.Q.n,"_-";   / chars allowed in a bare key; anything else must be "quoted"

trimstr:{[s] i:where not s in " \t"; $[count i;(first i)_(1+last i)#s;""]};   / strip leading/trailing space+tab; keep internal
isquoted:{[s] (1<count s) and all (first;last)@\:s="\""};
unquotekey:{[k] $[isquoted k;1_-1_k;k]};
stripcomment:{[l] (firstunquoted["#";l])#l};

parsekey:{[raw]
  / a bare (A-Za-z0-9_-) or "quoted" key or section name as a symbol; signals if invalid
  if[0=count raw;'"di.util.toml: empty key or section name"];
  if[not isquoted raw;
    if["." in raw;'"di.util.toml: dotted keys/sections are not supported (quote the name if the . is literal): ",raw];
    if[not all raw in keychars;'"di.util.toml: invalid bare name (only A-Za-z0-9_- allowed; quote otherwise): ",raw]];
  `$unquotekey raw};

sectname:{[hdr] parsekey trimstr hdr 1+til -2+count hdr};

instrmask:{[s]
  / per-char boolean: inside a "..." string, escape-aware
  if[0=count s;:0#0b];
  st:{[a;x] $[a 1;(a 0;0b); x="\\";(a 0;1b); x="\"";(not a 0;0b); (a 0;0b)]}\[(0b;0b);s];
  0b,-1_ st[;0]};

firstunquoted:{[c;s]
  / first index of char c outside a "..." string, or count s
  ?[;1b] (s=c) and not instrmask s};

splitassign:{[l]
  / (key;value) split on the first unquoted "="
  if[count[l]=eq:firstunquoted["=";l];'"di.util.toml: not a key = value line: ",l];
  trimstr each 0 1_'(0,eq)_l};

unescape:{[s]
  / expand \" \\ \n \t in one pass; signals on an unknown or dangling escape
  m:"\"nt\\"!"\"\n\t\\";
  r:{[m;a;c]
    $[a 1;[if[not c in key m;'"di.util.toml: invalid string escape: \\",c];(a[0],m c;0b)];
      c="\\";(a 0;1b);
      (a[0],c;0b)]}[m]/[("";0b);s];
  if[r 1;'"di.util.toml: dangling backslash in string"];
  r 0};

parsescalar:{[tok]
  / one scalar: "string", true, false, float or long; signals on anything else
  tok:trimstr tok;
  if[isquoted tok;:unescape 1_-1_tok];
  if[tok~"true"; :1b];
  if[tok~"false";:0b];
  if[null v:$[any tok in ".eE";"F"$tok;"J"$tok];
    '"di.util.toml: unparseable value (quote strings; bare words/datetimes are out of scope): ",tok];
  v};

splitcommas:{[s]
  / split an array's inner text on commas outside strings
  1_'_[;s] where (s=",") and not instrmask s:",",s};

parsevalue:{[v]
  / a "[ ... ]" array as a list of scalars, else a single scalar
  v:trimstr v;
  if[0=count v;'"di.util.toml: missing value"];
  if["["=first v;
    if[not "]"=last v;'"di.util.toml: malformed array (must be [ ... ]): ",v];
    inner:trimstr 1_-1_v;
    :$[0=count inner;();parsescalar each splitcommas inner]];
  parsescalar v};

addkv:{[d;k;v]
  / add k->v, signalling on a duplicate key or section
  if[k in key d;'"di.util.toml: duplicate key: ",string k];
  d,(enlist k)!enlist v};

addline:{[acc;line]
  / fold one line into acc (top;cursect;sect)
  top:acc 0; cursect:acc 1; sect:acc 2;
  $[(first line)="[";
    [hdr:trimstr line;
     if[not "]"=last hdr;'"di.util.toml: malformed section header (missing ]): ",line];
     if["[["~2 sublist hdr;'"di.util.toml: array-of-tables [[...]] is not supported: ",line];
     nm:sectname hdr;
     if[not null cursect;top:addkv[top;cursect;sect]];
     (top;nm;()!())];
    [kv:splitassign line;
     k:parsekey kv 0;
     v:parsevalue kv 1;
     $[null cursect;(addkv[top;k;v];cursect;sect);(top;cursect;addkv[sect;k;v])]]]};

parsetoml:{[text]
  / parse TOML text to a dict
  if[not 10h=abs type text;'"di.util.toml: parsetoml expects a char string; got type ",string type text];
  lines:trimstr each stripcomment each "\n" vs $[10h=type text;text;enlist text];
  acc:addline/[(()!();`;()!());lines where 0<count each lines];
  $[null acc 1;acc 0;addkv[acc 0;acc 1;acc 2]]};

parsefile:{[path]
  / read and parse a .toml file; signals if missing
  if[not 10h=abs type path;'"di.util.toml: parsefile expects a string path"];
  if[0=count key fsym:`$":",path;'"di.util.toml: file not found: ",path];
  parsetoml "\n" sv read0 fsym};

getapimeta:{[]
  / this module's api metadata, one row per callable function
  :flip `name`public`descrip`params`return!flip(
    (`parsetoml; 1b; "parse TOML text into a dict (one level of section nesting)"; "[string: toml text]"; "dict: setting->value (sections nest)");
    (`parsefile; 1b; "read and parse a .toml file into a dict (signals if missing)"; "[string: file path]"; "dict: setting->value"));
  };
