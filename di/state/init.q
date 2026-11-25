/ snapshot the whole state of a q process - every namespace, variable and view, and the system
/ settings - and report what changed between two snapshots: what a script, a module load or a
/ function call left behind

/ module version from the VERSION file
version:first read0`:::VERSION;

/ a random id, so a capture can recognise this module's namespace and leave it out
id:first 1?0Ng;

/ ------------------------------------------------------------------ walking the process

/ is x a namespace? (a dict whose first key is the null symbol `)
isns:{[x] :$[99h=type x;(`)~first key x;0b];};

/ is namespace dict d this module's own? Its saved states change on every capture
isself:{[d] :$[`id in key d;id~d`id;0b];};

/ one namespace's dict, or an empty one if it cannot be read
readns:{[n] :@[get;n;(0#`)!()];};

/ the members of namespace p, fully qualified: root vars stay bare (qsp), others are qualified (.Q.pf)
qualify:{[p;names] :$[p~`.;names;` sv/:p,/:names];};

/ the views defined in namespace p, fully qualified
viewsin:{[p] :qualify[p;@[system;"b ",string p;`symbol$()]];};

/ an error as a value
errorof:{[e] :`$"error: ",e;};

/ what a view would give, or the error it gives. A root view is read as ..v: a bare name would be
/ looked up in this module's namespace
viewvalue:{[v] :@[get;$["."=first s:string v;v;`$"..",s];errorof];};

walk:{[p;d]
  / every namespace, variable and view below namespace p (dict d): (namespaces;name!value;views)
  / a view is recorded as its value - its definition is all its namespace holds. Nothing in the root
  / dict is a namespace: those are the other entries of key`, and a handle such as mod is one value
  d:(key[d]except`)#d;
  nm:qualify[p;key d];
  v:value d;
  n:$[p~`.;count[v]#0b;isns each v];
  k:where not n&@[n;where n;:;isself each v where n];
  nm:nm k;
  v:v k;
  n:n k;
  vw:viewsin p;
  w:where nm in vw;
  v[w]:viewvalue each nm w;
  sub:.z.s'[nm where n;v where n];
  vars:(,/)[(nm where not n)!v where not n;sub@\:1];
  :((nm where n),raze sub@\:0;vars;vw,raze sub@\:2);
  };

/ system settings a capture records (not \S: the random seed moves on every ?)
syscmds:("c";"C";"d";"e";"g";"o";"p";"P";"s";"t";"T";"W";"z";"cd");

/ one system setting, or the error reading it gives
readsys:{[c] :@[system;c;errorof];};

/ every system setting a capture records, by its command (`\c`\P...)
sysnow:{[] :(`$"\\",/:syscmds)!readsys each syscmds;};

getstate:{[]
  / the state of the process now: its namespaces, every variable (fully qualified), its views and
  / its system settings. Attributes are recorded separately: q applies one in place, so a saved
  / value gains it too. fp is 1b for a fingerprint (see fingerprint)
  top:` sv/:`,/:key`;
  w:walk'[top;readns each top];
  ns:(top except`.),raze w@\:0;
  vars:(,/)[(0#`)!();w@\:1];
  :`ns`vars`attrs`views`sys`fp!(ns;vars;attrsof each vars;raze w@\:2;sysnow[];0b);
  };

/ ------------------------------------------------------------------ fingerprints

/ values bigger than this, serialised, are fingerprinted without an md5
hashlimit:10000000;

attrs:{[x]
  / the attributes of x and of its parts, which ~ ignores: a list's own, each column of a table, a
  / dictionary's key and value
  t:type x;
  if[t=98h;:attr each value flip x];
  if[t=99h;:(attrs key x;attrs value x)];
  :attr x;
  };

/ the attributes of x, or ` if they cannot be read (a partitioned table keeps them on disk)
attrsof:{[x] :@[attrs;x;`];};

/ the serialised size of x, or null if it cannot be serialised
sizeof:{[x] :@[-22!;x;0N];};

fp:{[x;a]
  / a fingerprint of value x with attributes a: (type;count;attributes;serialised size;md5 of the
  / serialised value). The md5 is empty above hashlimit, so a same-sized change to a big value goes unseen
  s:sizeof x;
  h:$[s within(0;hashlimit);md5"c"$-8!x;0#0x00];
  :(type x;@[count;x;0N];a;s;h);
  };

fingerprint:{[s]
  / a state with each value replaced by its fingerprint. It holds no references to the process's
  / values, so it is small, and it can be saved with set and compared in another process
  if[s`fp;:s];
  s[`vars]:fp'[s`vars;s`attrs];
  s[`fp]:1b;
  :s;
  };

/ ------------------------------------------------------------------ saved states

/ the state when the module loaded, and the last two captures. \d and \e are left out of it: they
/ hold other values while a module loads
startup:getstate[];
startup[`sys]:(`$("\\d";"\\e"))_startup`sys;
current:startup;
previous:startup;

/ saved states by name, seeded with a generic null so values stay a general list
states:(1#`)!enlist(::);

/ signal unless sn is a symbol atom
isname:{[sn] if[-11h<>type sn;'"statename must be a symbol atom, `likethis"];};

/ is s a state, as getstate or fingerprint return them?
isstate:{[s] :$[99h=type s;`ns`vars`attrs`views`sys`fp~key s;0b];};

keep:{[sn;s]
  / save state s under the name sn, and make it the latest capture
  .z.m.previous:current;
  .z.m.current:s;
  .z.m.states[sn]:s;
  };

/ capture the current state under the name sn
setstate:{[sn] isname sn;keep[sn;getstate[]];};

/ capture a fingerprint of the current state under the name sn: holds no references to values
setfingerprint:{[sn] isname sn;keep[sn;fingerprint getstate[]];};

addstate:{[sn;s]
  / save a state taken elsewhere under the name sn: a fingerprint loaded from disk, or from another process
  isname sn;
  if[not isstate s;'"not a state: use getstate or fingerprint"];
  keep[sn;s];
  };

/ names of all saved states
statenames:{[] :1_key states;};

/ signal unless every name in sns is a saved state
known:{[sns] sns:(),sns;if[not all sns in statenames[];'"no saved state: ",", "sv string sns except statenames[]];};

dropstate:{[sn]
  / forget a saved state: each one holds a reference to every value the process had when it was taken
  known sn;
  .z.m.states:(enlist sn)_states;
  };

/ ------------------------------------------------------------------ what is left out

/ names never reported - .z.ex and .z.ey are set by the debugger whenever you are at a q)) prompt
ignorelist:`.z.ex`.z.ey;

/ every name a report leaves out (the module's own namespace is never captured at all)
ignored:{[] :ignorelist;};

/ never report names; a name that is a namespace hides everything below it (`.m hides all module internals)
ignore:{[names] .z.m.ignorelist:distinct ignorelist,names;:ignored[];};

/ report names again
unignore:{[names] .z.m.ignorelist:ignorelist except names;:ignored[];};

/ does each string in s name something inside namespace p?
under:{[s;p] q:string[p],".";:((count each s)>count q)&q~/:(count q)#'s;};

hidden:{[ig;names]
  / which of names ig leaves out: the name itself, or a namespace it is inside. `. hides root variables
  s:string names;
  inroot:(`. in ig)&not"."=first each s;
  :(names in ig)|inroot|(|/)[0b;under[s]each ig];
  };

/ names, less those ig leaves out
shown:{[ig;names] :names where not hidden[ig;names];};

/ ------------------------------------------------------------------ reports

/ the namespace a fully qualified name lives in: .Q.pf -> .Q, .m.di.0qsp.f -> .m.di.0qsp, qsp -> ., .m -> .
nsof:{[x] :$["."<>first s:string x;`.;0=i:last ss[s;"."];`.;`$i#s];};

nsreport:{[ig;b4;aftr]
  / one `ns row per namespace that appeared or disappeared
  b4:shown[ig;b4];
  aftr:shown[ig;aftr];
  removed:b4 except aftr;
  added:aftr except b4;
  names:removed,added;
  n:count names;
  :([]ns:nsof each names;name:names;kind:n#`ns;change:raze(count each(removed;added))#'`removed`added;
    before:n#enlist(::);after:n#enlist(::));
  };

varreport:{[ig;b4;aftr]
  / one `var or `view row per variable or view that appeared, disappeared or holds a different value
  b:b4`vars;
  a:aftr`vars;
  b:shown[ig;key b]#b;
  a:shown[ig;key a]#a;
  removed:key[b]except key a;
  added:key[a]except key b;
  common:key[b]inter key a;
  changed:common where not(b[common]~'a common)&b4[`attrs;common]~'aftr[`attrs;common];
  names:removed,added,changed;
  kind:`var`view names in b4[`views],aftr`views;
  / seeded with a generic null so a missing var shows as :: rather than a typed null
  none:enlist[`]!enlist(::);
  :([]ns:nsof each names;name:names;kind:kind;change:raze(count each(removed;added;changed))#'`removed`added`changed;
    before:(none,b)names;after:(none,a)names);
  };

sysreport:{[ig;b;a]
  / one `sys row per system setting that differs
  k:shown[ig;key[a]inter key b];
  k:k where not b[k]~'a k;
  n:count k;
  :([]ns:n#`$"\\";name:k;kind:n#`sys;change:n#`changed;before:b k;after:a k);
  };

diff:{[b4;aftr]
  / what changed from state b4 to state aftr, one row per change. kind is `ns (a namespace appeared
  / or disappeared), `var, `view or `sys (a system setting). If either is a fingerprint, both are
  / compared as fingerprints
  if[b4[`fp]|aftr`fp;b4:fingerprint b4;aftr:fingerprint aftr];
  ig:ignorelist;
  r:nsreport[ig;b4`ns;aftr`ns],varreport[ig;b4;aftr],sysreport[ig;b4`sys;aftr`sys];
  :`ns`kind`name xasc r;
  };

comparestate:{[s1;s2]
  / what changed between two saved states
  if[not(1#-11h)~distinct type each(s1;s2);'"statenames must be symbol atoms, `likethis"];
  known(s1;s2);
  :diff[states s1;states s2];
  };

/ what changed between the last two captures
lastchanges:{[] :diff[previous;current];};

/ what changed since the last capture, without capturing
sincelast:{[] :diff[current;getstate[]];};

/ what changed since the module loaded
sincestartup:{[] :diff[startup;getstate[]];};

around:{[f;args]
  / apply f to the list args, and return what it gave back and what it changed: `result`changes
  b:getstate[];
  r:f . args;
  :`result`changes!(r;diff[b;getstate[]]);
  };

summary:{[rpt]
  / one row per namespace of a report, counting each kind of change
  :select nsadded:sum(kind=`ns)&change=`added,nsremoved:sum(kind=`ns)&change=`removed,
    added:sum(kind<>`ns)&change=`added,changed:sum(kind<>`ns)&change=`changed,
    removed:sum(kind<>`ns)&change=`removed by ns from rpt;
  };

collapse:{[rpt]
  / a report with each namespace that appeared or disappeared folded to its one `ns row: what is
  / inside it is dropped, leaving the new and deleted namespaces plus every change to what remained
  :select from rpt where not ns in exec name from rpt where kind=`ns;
  };

export:([
  / capture
  setstate;setfingerprint;addstate;statenames;dropstate;getstate;fingerprint;
  / report
  comparestate;diff;lastchanges;sincelast;sincestartup;around;summary;collapse;
  / what is left out
  ignore;unignore;ignored;
  version]);
