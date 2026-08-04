/ scoped-down TOML parser for the modular torq world - reads settings .toml files (and text) into a
/ q dict. supports: key=value (bare or "quoted" keys), quote-aware # comments, one level of [section]
/ nesting, and scalars (quoted strings, integer->long, float, true/false, flat arrays). not supported:
/ inline tables, dotted keys, single-quoted/multi-line strings, datetimes, array-of-tables.
/ fail-loud: anything it cannot correctly parse signals 'di.util.toml: ...', never silent garbage.
/ strings parse to q char strings, never symbols (TOML has none) - callers coerce with `$ at use.
/ pure: no init/logger/deps - di.config loads it during config resolution, before a logger exists.
/ parsefile signals on a MISSING file; a caller for whom that is acceptable (a cascade probing
/ optional tiers) guards existence itself first, as di.config does: if[0=count key hsym`$path;:()!()].
/ reserved-word trap: cut/trim/parse/ss/sv/vs/ssr are builtins - hence trimstr/parsetoml/etc.

keychars:.Q.a,.Q.A,.Q.n,"_-";   / chars allowed in a bare key; anything else must be "quoted"

trimstr:{[s] i:where not s in " \t"; $[count i;(first i)_(1+last i)#s;""]};   / strip leading/trailing space+tab; keep internal
isquoted:{[s] (1<count s) and all (first;last)@\:s="\""};
unquotekey:{[k] $[isquoted k;1_-1_k;k]};
stripcomment:{[l] (firstunquoted["#";l])#l};

parsekey:{[raw]
  / validate + resolve a bare-or-"quoted" key OR section name to a symbol - both follow the same
  / rule. a bare name is A-Za-z0-9_- only; a "quoted" name takes any chars (a "." is then literal).
  / empty, dotted-bare (nesting, out of scope), and invalid-bare names all signal.
  if[0=count raw;'"di.util.toml: empty key or section name"];
  if[not isquoted raw;
    if["." in raw;'"di.util.toml: dotted keys/sections are not supported (quote the name if the . is literal): ",raw];
    if[not all raw in keychars;'"di.util.toml: invalid bare name (only A-Za-z0-9_- allowed; quote otherwise): ",raw]];
  `$unquotekey raw};

sectname:{[hdr] parsekey trimstr hdr 1+til -2+count hdr};

instrmask:{[s]
  / per-position boolean: is this char inside a "..." string? escape-aware - a \" or \\ inside a
  / string does not toggle the state. carries (in-string?; prev-char-was-an-escaping-backslash?) and
  / returns the state BEFORE each char (0b prepended, last state dropped). used by both scanners
  / below so comment/= detection and array-comma splitting handle escaped quotes identically.
  if[0=count s;:0#0b];
  st:{[a;x] $[a 1;(a 0;0b); x="\\";(a 0;1b); x="\"";(not a 0;0b); (a 0;0b)]}\[(0b;0b);s];
  0b,-1_ st[;0]};

firstunquoted:{[c;s]
  / first index of char c outside a "..." string (or count s if none); c is only ever "#" or "=".
  ?[;1b] (s=c) and not instrmask s};

splitassign:{[l]
  / (key;value) split on the first unquoted "=" ; a line with no "=" is malformed.
  if[count[l]=eq:firstunquoted["=";l];'"di.util.toml: not a key = value line: ",l];
  trimstr each 0 1_'(0,eq)_l};

unescape:{[s]
  / expand \" \\ \n \t in one left-to-right pass, signalling on an unknown or dangling escape. a
  / single pass (not an ordered ssr-chain) is needed so a \\ next to an escape char resolves right.
  m:"\"nt\\"!"\"\n\t\\";
  r:{[m;a;c]
    $[a 1;[if[not c in key m;'"di.util.toml: invalid string escape: \\",c];(a[0],m c;0b)];
      c="\\";(a 0;1b);
      (a[0],c;0b)]}[m]/[("";0b);s];
  if[r 1;'"di.util.toml: dangling backslash in string"];
  r 0};

parsescalar:{[tok]
  / one scalar: "quoted string" | true | false | float (has "." or an e/E exponent) | long. an
  / unquoted non-numeric token (a bare word, a datetime) parses to a null and is rejected.
  tok:trimstr tok;
  if[isquoted tok;:unescape 1_-1_tok];
  if[tok~"true"; :1b];
  if[tok~"false";:0b];
  if[null v:$[any tok in ".eE";"F"$tok;"J"$tok];
    '"di.util.toml: unparseable value (quote strings; bare words/datetimes are out of scope): ",tok];
  v};

splitcommas:{[s]
  / split an array's inner text on top-level commas (a comma inside "..." is not a separator;
  / escape-aware via instrmask). prepend a comma so the first element uses the same cut-and-drop rule.
  1_'_[;s] where (s=",") and not instrmask s:",",s};

parsevalue:{[v]
  / a "[ ... ]" array -> list of scalars (empty -> ()); else a single scalar. empty and unterminated
  / values are rejected.
  v:trimstr v;
  if[0=count v;'"di.util.toml: missing value"];
  if["["=first v;
    if[not "]"=last v;'"di.util.toml: malformed array (must be [ ... ]): ",v];
    inner:trimstr 1_-1_v;
    :$[0=count inner;();parsescalar each splitcommas inner]];
  parsescalar v};

addkv:{[d;k;v]
  / add k->v, signalling on a duplicate (a repeated key/section, or a key/section clash - TOML errors).
  / catenation (not ,:) keeps the value list general so mixed value types never hit a type-widen error.
  if[k in key d;'"di.util.toml: duplicate key: ",string k];
  d,(enlist k)!enlist v};

addline:{[acc;line]
  / fold step; acc is (top;cursect;sect). a [section] flushes the open section into top and opens a
  / fresh one; a key=value goes into the current section, or top before any section.
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
  / TOML text -> dict (one level of [section] nesting). accepts a string (or the char atom q makes of
  / a 1-char literal); other types signal - else a 1-char input is an atom and ssr/vs throw 'type.
  if[not 10h=abs type text;'"di.util.toml: parsetoml expects a char string; got type ",string type text];
  lines:trimstr each stripcomment each "\n" vs $[10h=type text;text;enlist text];
  acc:addline/[(()!();`;()!());lines where 0<count each lines];
  $[null acc 1;acc 0;addkv[acc 0;acc 1;acc 2]]};

parsefile:{[path]
  / read + parse a .toml file. a MISSING file signals (a cascade caller guards existence itself).
  if[not 10h=abs type path;'"di.util.toml: parsefile expects a string path"];
  if[0=count key fsym:`$":",path;'"di.util.toml: file not found: ",path];
  parsetoml "\n" sv read0 fsym};

getapimeta:{[]
  / callable-api metadata for di.torq to register with di.api (getapimeta itself is plumbing, omitted).
  :flip `name`public`descrip`params`return!flip(
    (`parsetoml; 1b; "parse TOML text into a dict (one level of section nesting)"; "[string: toml text]"; "dict: setting->value (sections nest)");
    (`parsefile; 1b; "read and parse a .toml file into a dict (signals if missing)"; "[string: file path]"; "dict: setting->value"));
  };
