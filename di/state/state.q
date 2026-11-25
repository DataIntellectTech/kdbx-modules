//=========CONFIG & INITIALISATION===========//
/Define shared util funcs and globals etc.

.state.nss:{` sv/:`,/:key`} /Get current namespaces in `.q`.z`.Q... format
.state.getstate:{ns!{@[value;x;(0#`)!()]}each ns:.state.nss[]} /evaluate each found namespace (all vars!their values)
@[`.state;;:;.state.getstate[]]@/:`STARTUP_STATE`currentstate`previousstate; /set everything to the initial state when this code loads
.state.states:(1#`)!enlist(::) /seed with a generic null so values stay a general list (never collapse to a table)

/names never reported. A name that is a namespace hides everything below it,
/so e.g. adding `.m here hides all module internals. Add/remove to taste:
/  .state.IGNORE,:`.m      .state.IGNORE:.state.IGNORE except`.z.ex`.z.ey
.state.IGNORE:`.state.states`.state.STARTUP_STATE`.state.currentstate`.state.previousstate, /bookkeeping vars that change on every capture
 `.z.ex`.z.ey /set by the debugger whenever you are at a q)) prompt
//================MAIN LOGIC=================//
/Define the functions/api tht can be used to find and report on anything
/that changed since the last state-capture
/when this code runs there is already a defined state (STARTUP_STATE etc.)

/capture the current state under name sn, and roll currentstate -> previousstate
.state.setstate:{[sn]
 if[not(-11h)~type sn;'"ERROR:statename must be symbol atom, `likethis."];
 s:.state.getstate[];
 .state.previousstate:.state.currentstate;
 .state.currentstate:s;
 @[`.state.states;sn;:;s];
 }

/names of all saved states
.state.statenames:{1_key .state.states}

/is x a namespace? (a dict whose first key is the null symbol `)
.state.isns:{$[99h=type x;(`)~first key x;0b]}

/split namespace p (dict d) into fully-qualified names, dropping the ` marker and anything in IGNORE
/returns (names;values;isnamespace flags). Root vars stay bare (qsp), others get qualified (.Q.pf)
.state.nsitems:{[p;d]
 d:(key[d]except`)#d;
 nm:$[p~`.;key d;` sv/:p,/:key d];
 k:where not nm in .state.IGNORE;
 (nm k;value[d]k;.state.isns each value[d]k)
 }

/flatten one namespace into fully-qualified name!value, recursing into sub-namespaces (e.g. .m.di.0qsp)
.state.flatns:{[p;d]
 i:.state.nsitems[p;d];nm:i 0;v:i 1;n:i 2;
 (,/)[(nm where not n)!v where not n;.z.s'[nm where n;v where n]]
 }

/every sub-namespace name below namespace p, recursively
.state.subns:{[p;d]
 i:.state.nsitems[p;d];nm:i[0]where i 2;
 nm,raze .z.s'[nm;i[1]where i 2]
 }

/top-level namespaces of a state, honouring IGNORE
.state.topns:{key[x]except .state.IGNORE}

/flatten a whole state (ns!nsdict) into one dict of every variable in the process
.state.flat:{n:.state.topns x;(,/)[(0#`)!();.state.flatns'[n;x n]]}

/every namespace in a state, top-level and nested (root . excluded - it always exists)
.state.allns:{n:.state.topns[x]except`.;n,raze .state.subns'[n;x n]}

/namespace a fully-qualified name lives in: .Q.pf -> .Q, .m.di.0qsp.f -> .m.di.0qsp, qsp -> ., .m -> .
.state.nsof:{$["."<>first s:string x;`.;0=i:last ss[s;"."];`.;`$i#s]}

/core diff of two states (the ns!nsdict dicts getstate returns).
/one row per change: kind is `ns (a namespace appeared/disappeared) or `var
.state.diff:{[b4;aftr]
  /namespace level
  b4ns:.state.allns b4; aftrns:.state.allns aftr;
  nsremoved:b4ns except aftrns; /namespaces that were deleted
  nsadded:aftrns except b4ns; /namespaces that were created
  nsnames:nsremoved,nsadded;
  nsrpt:([]ns:.state.nsof each nsnames;name:nsnames;kind:count[nsnames]#`ns;
    change:raze(count each(nsremoved;nsadded))#'`removed`added;
    before:count[nsnames]#enlist(::);after:count[nsnames]#enlist(::));
  /variable level
  b4:.state.flat b4; /every var in the before state, fully qualified
  aftr:.state.flat aftr; /every var in the after state, fully qualified
  removed:key[b4]except key aftr; /vars that were deleted
  added:key[aftr]except key b4; /vars that were created
  common:key[b4]inter key aftr;
  changed:common where not b4[common]~'aftr common; /vars that exist in both but whose value differs
  names:removed,added,changed;
  /seed with a generic null so a missing var shows as :: rather than a typed null
  varrpt:([]ns:.state.nsof each names;name:names;kind:count[names]#`var;
    change:raze(count each(removed;added;changed))#'`removed`added`changed;
    before:((enlist[`]!enlist(::)),b4)names;after:((enlist[`]!enlist(::)),aftr)names);
  `ns`kind`name xasc nsrpt,varrpt
 }

/compare two named states saved with setstate
.state.comparestate:{[s1;s2]
  if[not(1#-11h)~distinct type each(s1;s2);'"ERROR: statenames must be symbol atoms `likethis."];
  if[not all(s1;s2)in\:.state.statenames[];'"ERROR: all statenames must exist";];
  .state.diff[.state.states s1;.state.states s2]
 }

/shortcuts
.state.lastchanges:{.state.diff[.state.previousstate;.state.currentstate]} /between the last two setstate calls
.state.sincelast:{.state.diff[.state.currentstate;.state.getstate[]]} /since the last setstate, without capturing
.state.sincestartup:{.state.diff[.state.STARTUP_STATE;.state.getstate[]]} /since this file was loaded

/summary of any report above: one row per namespace with counts of each kind of change
/ e.g. .state.summary .state.comparestate[`initstate;`endstate]
.state.summary:{[rpt]
  select nsadded:sum(kind=`ns)&change=`added,nsremoved:sum(kind=`ns)&change=`removed,
    added:sum(kind=`var)&change=`added,changed:sum(kind=`var)&change=`changed,removed:sum(kind=`var)&change=`removed
    by ns from rpt
 }

/any report above with each namespace that appeared or disappeared folded to its one `ns row:
/what is inside it (vars and nested namespaces) is dropped, so what is left is the new namespaces
/plus every change to things that already existed
/ e.g. .state.collapse .state.comparestate[`initstate;`endstate]
.state.collapse:{[rpt]
  select from rpt where not ns in exec name from rpt where kind=`ns
 }
