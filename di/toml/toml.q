// a small TOML parser for the modular torq world - scoped down for v1 to what real settings files
// actually need: key = value pairs (bare or double-quoted keys), whole-line and trailing # comments
// (quote-aware, so a "#" inside a string is not a comment), one level of [section] nesting (a
// section becomes a sub-dict keyed by the section name), and scalar values - double-quoted strings
// (\" \\ \n \t escapes), integers, floats, true/false, and flat arrays of any of those.
// deliberately NOT supported: nested inline tables ({a=1,b=2}), dotted keys (a.b.c), single-quoted
// literal strings, multi-line strings, datetimes, array-of-tables ([[section]]).
// FAIL-LOUD by design (this is a SHARED utility used by many modules, not just di.config): anything
// it cannot correctly parse SIGNALS a clear 'di.toml: ...' error rather than silently returning
// nulls/garbage - a missing file, a line with no "=", an unparseable value (bare word / datetime),
// an invalid bare key (a space/":"/etc. - i.e. most non-TOML lines that happen to contain "="), an
// empty key, a dotted key, a duplicate key/section, and a malformed or array-of-tables section
// header. **A caller that treats a missing file as acceptable
// (a config cascade probing optional tiers) must guard existence ITSELF before calling** - the way
// di.config does (if[0=count key hsym`$path;:()!()]); di.toml does not silently paper over it.
// POLICY-FREE strings: every TOML string parses to a q char string (10h), NEVER a symbol (TOML has
// no symbol type), so callers coerce with `$ at the point of use. integers parse to LONG (matching
// what `value` gives a .q settings line), floats to float.
// PURE module: no init, no logger, no injected deps - loaded during config resolution before any
// logger exists, so it SIGNALS (does not log).
// NOTE (reserved-word trap): q builtins cut/trim/parse/ss/sv/vs/ssr cannot be local names - helpers
// are named trimstr/parsetoml/etc.; check `name in .Q.res before reusing a short name.

// characters allowed in a bare (unquoted) key - anything else (a space, ":", etc.) must be
// double-quoted, so a non-TOML line that happens to contain "=" fails loud instead of parsing to a
// bogus symbol key.
keychars:.Q.a,.Q.A,.Q.n,"_-";

trimstr:{[s]
  // trim leading/trailing whitespace, treating tabs as spaces.
  trim ssr[s;"\t";" "]
  };

isquoted:{[s]
  // true if s is a double-quoted literal ("...").
  (1<count s) and all (first;last)@\:s="\""
  };

firstunquoted:{[c;s]
  // index of the first occurrence of char c in s that is OUTSIDE a double-quoted span, or count s
  // if none. a running parity of quote characters marks whether each position is inside a string.
  ?[;1b] (c=s) and not mod[;2] sums s="\""
  };

stripcomment:{[l]
  // drop a trailing # comment, but not a "#" that appears inside a "..." string.
  (firstunquoted["#";l])#l
  };

splitassign:{[l]
  // split a line on its first unquoted "=" into (key;value), both trimmed. a line with no "=" is a
  // malformed settings line - signal it (pure module: no logger to route through).
  eq:firstunquoted["=";l];
  if[count[l]=eq;'"di.toml: not a key = value line: ",l];
  trimstr each 0 1_'(0,eq)_l
  };

unquotekey:{[k]
  // strip surrounding double-quotes from a key if present; a bare key is returned unchanged.
  $[isquoted k;1_-1_k;k]
  };

unescape:{[s]
  // expand the supported string escapes. applied as sequential replacements (\\ last); a literal
  // backslash immediately followed by an escape char is an accepted edge (see toml.md).
  ssr/[s;("\\\"";"\\n";"\\t";"\\\\");("\"";"\n";"\t";"\\")]
  };

parsescalar:{[tok]
  // parse one scalar token: a double-quoted string (unescaped, kept as a q string), true/false, a
  // float (has a "."), else a long integer. an unquoted non-numeric token (a bare word, a datetime)
  // parses to a null and is REJECTED - real strings must be quoted.
  tok:trimstr tok;
  if[isquoted tok;:unescape 1_-1_tok];
  if[tok~"true"; :1b];
  if[tok~"false";:0b];
  v:$[tok like "*.*";"F"$tok;"J"$tok];
  if[null v;'"di.toml: unparseable value (quote strings; bare words/datetimes are out of scope): ",tok];
  v
  };

splitcommas:{[s]
  // split a "[...]" array's inner text on TOP-LEVEL commas (a comma inside a quoted element is not
  // a separator). prepend a comma so the first element is captured by the same cut-and-drop rule.
  1_'_[;s] where (s=",") and not mod[;2] sums "\""=s:",",s
  };

parsevalue:{[v]
  // parse a value: a "[...]" array into a list of scalars (empty array -> ()), an empty value into
  // an empty string, anything else as a single scalar.
  v:trimstr v;
  if[0=count v;:""];
  if["["=first v;
    inner:trimstr 1_-1_v;
    :$[0=count inner;();parsescalar each splitcommas inner]];
  parsescalar v
  };

sectname:{[l]
  // the section name from a "[name]" header line.
  `$trimstr l 1+til -2+count l
  };

addkv:{[d;k;v]
  // add key k -> value v to dict d, SIGNALLING on a duplicate - a repeated key, a repeated section,
  // or a key/section-name clash are all TOML errors and must not silently last-win. catenation (not
  // ,: in-place) keeps the value list general, so mixing scalar / string / sub-dict / list values
  // never hits a type-widen error.
  if[k in key d;'"di.toml: duplicate key: ",string k];
  d,(enlist k)!enlist v
  };

addline:{[acc;line]
  // fold step over the settings lines. acc is (top; cursect; sect): the top-level dict, the current
  // section name (` before any [section]), and the current section's accumulating dict. a [section]
  // header flushes the open section into top and opens a fresh one; a key = value goes into the
  // current section, or into top if no section is open yet. anything malformed signals.
  top:acc 0; cursect:acc 1; sect:acc 2;
  $[(first line)="[";
    [hdr:trimstr line;
     if[not "]"=last hdr;'"di.toml: malformed section header (missing ]): ",line];
     if["[["~2 sublist hdr;'"di.toml: array-of-tables [[...]] is not supported: ",line];
     nm:sectname line;
     if[null nm;'"di.toml: empty section name: ",line];
     if[not null cursect;top:addkv[top;cursect;sect]];
     (top;nm;()!())];
    [kv:splitassign line;
     rawkey:kv 0;
     if[0=count rawkey;'"di.toml: empty key: ",line];
     if[not isquoted rawkey;
       if["." in rawkey;'"di.toml: dotted keys are not supported (quote the key if the dot is literal): ",rawkey];
       if[not all rawkey in keychars;'"di.toml: invalid bare key (only A-Za-z0-9_- allowed; quote the key otherwise): ",rawkey]];
     k:`$unquotekey rawkey;
     v:parsevalue kv 1;
     $[null cursect;(addkv[top;k;v];cursect;sect);(top;cursect;addkv[sect;k;v])]]]
  };

parsetoml:{[text]
  // parse TOML text (a single string) into a dict; one level of [section] nesting (a section's dict
  // is the value of its key). blank and comment-only lines contribute nothing. accepts a char string
  // (or the char atom q makes of a 1-char literal, normalised to a string); any other type signals -
  // without this a 1-char input is a char atom and ssr/vs throw a cryptic 'type.
  if[not 10h=abs type text;'"di.toml: parsetoml expects a char string; got type ",string type text];
  text:$[10h=type text;text;enlist text];
  lines:trimstr each stripcomment each "\n" vs text;
  lines:lines where 0<count each lines;
  acc:addline/[(()!();`;()!());lines];
  top:acc 0;
  if[not null acc 1;top:addkv[top;acc 1;acc 2]];
  top
  };

parsefile:{[path]
  // read and parse a .toml file into a dict. a MISSING file SIGNALS - di.toml fails loud so a caller
  // that mistypes a path or loses a required file finds out immediately. a caller that treats a
  // missing file as acceptable (a config cascade probing optional tiers) must guard existence ITSELF
  // before calling, the way di.config does: if[0=count key hsym`$path;:()!()].
  fsym:`$":",path;
  if[0=count key fsym;'"di.toml: file not found: ",path];
  parsetoml "\n" sv read0 fsym
  };

getapimeta:{[]
  // this module's api metadata, one row per CALLABLE API function, for di.torq to register with
  // di.api. getapimeta itself is plumbing (di.torq calls it by convention) and is deliberately NOT
  // listed - the registry describes the callable api, not plumbing. names are bare (di.torq qualifies).
  :flip `name`public`descrip`params`return!flip(
    (`parsetoml; 1b; "parse TOML text into a dict (one level of [section] nesting)";               "[string: toml text]"; "dict: setting -> value (sections as sub-dicts)");
    (`parsefile; 1b; "read and parse a .toml file into a dict (signals if the file is missing)";   "[string: file path]"; "dict: setting -> value"));
  };