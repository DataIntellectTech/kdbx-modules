/ di.qsp.tree - the shape of a q parse tree
/ everything qsp knows about how q represents a query lives here, and every shape is detected
/ from q's own parser at load rather than assumed, so a change in representation between q
/ versions shows up as a load failure or a refusal - never as a silently mis-read tree
/ leaf module: depends on nothing

/ ------------------------------------------------------------------ refusal
/ every refusal in qsp is a signal prefixed "qsp: ". Nothing is refused by returning a value,
/ so a caller that forgets to check cannot run past one

chk:{[b;m] if[not b;'"qsp: ",m];};
prefix:{[m] :$[(5<=count m)and"qsp: "~5#m;m;"qsp: ",m];};

/ a fault is a refusal that withholds nothing: the caller holds the column, the walker just
/ could not carry it through the expression it was read out of. The audit log records it as an
/ error rather than a denial, so the trail does not show an entitled caller being denied what
/ nobody denied them. It is marked with a leading byte no denial can start with - every denial
/ message begins with fixed text - and the mark is stripped before anyone sees the message. No
/ state is set, so nothing can leak between queries
fault:{[m] '"\001qsp: ",m};
isfault:{[m] :(10h=type m)and"\001"~first m;};
clean:{[m] :$[isfault m;1_m;m];};

/ q's own message, or a description of last resort. Some q errors signal with an empty or blank
/ message, and a refusal that names nothing cannot be acted on by a reader of the audit log or by
/ a caller trying to reformulate
described:{[e]
  m:$[10h=type e;e;-11h=type e;string e;""];
  :$[0<count trim m;m;"the database would not evaluate this query"];
  };

/ ------------------------------------------------------------------ query nodes

/ the ? and ! operators at the head of a select and of an update/delete
selop:(parse"select from qspprobe")0;
updop:(parse"delete from qspprobe")0;

/ is the constraint slot wrapped in an extra enlist by this q version?
cnested:1=count (parse"select from qspprobe where a=1,b=2")2;

/ the grades of select[<c] and select[>c], which parse leaves as (enlist (op;expression)). They are
/ the same primitives as hopen and hclose, which q applies to an atom
ascop:first first last parse"select[<a] from qspprobe";
descop:first first last parse"select[>a] from qspprobe";

/ slot -> constraints
getc:{[s] :$[0=count s;();cnested;first s;s];};
/ constraints -> slot
setc:{[c] :$[0=count c;();cnested;enlist c;c];};

/ literal data inside a parse tree is enlist-wrapped: `trade is a reference to the variable,
/ (enlist `trade) is the symbol itself
lit:{[x] :$[(0h=type x)|11h=abs type x;enlist x;x];};

isfn:{[x] :(type x) within 100 112;};
isquery:{[x] :$[0h<>type x;0b;5>count x;0b;(first[x]~selop)|first[x]~updop];};
hasquery:{[x] :$[isquery x;1b;0h=type x;any .z.s each x;0b];};

/ a join may stand in the table slot of a select. Parse trees hold the join's value, so
/ membership is by identity
joins:(ej;aj;aj0;lj;ij;pj;uj;wj;wj1);
isjoin:{[x] :$[0h<>type x;0b;3>count x;0b;not isfn h:first x;0b;any h~/:joins];};

namerefs:{[x]
  / every name an expression references, head included: in (sym where time=min time)[0] the
  / columns are inside the head, and "price where size>100" indexes the column price. A head
  / that names a function rather than a column is harmless here - callers intersect the result
  / with a table's columns - and a symbol vector of two or more is a call that collapsed, whose
  / head is the call's name
  :$[-11h=type x;enlist x;
    (11h=type x)&1<count x;x;
    (0h=type x)&1<count x;raze .z.s each x;
    `symbol$()];
  };

basequeries:{[x]
  / every select/exec/update/delete whose table slot is a table name: exactly the set of reads a
  / query performs. Both sides of a join appear; a select over a select, or an update wrapping
  / one, adds none of its own
  :$[isquery x;$[-11h=type x 1;enlist x;()],raze .z.s each x;
    0h=type x;raze .z.s each x;
    ()];
  };
basetables:{[x] :distinct `symbol$({x 1} each basequeries x);};

/ ------------------------------------------------------------------ filesystem guard
/ a file handle is a symbol beginning with ":". No analytic query needs one and every filesystem
/ primitive requires one - including hdel, which is the same primitive as not (see fns.q)

isfilehandle:{[s] :$[0=count c:string s;0b;":"=first c];};
hasfilehandle:{[x] :$[11h=abs type x;any isfilehandle each (),x;0h=type x;any .z.s each x;0b];};

/ ------------------------------------------------------------------ policy markers
/ placeholders a policy filter may contain, resolved to plain literals when a query is rewritten
/ (policy.q). Resolving at rewrite rather than at run time means the tree that runs contains no
/ reference to qsp state, and the audit log records the value that was actually applied

/ (agedmark;column;span) - built by f.aged
agedmark:`$"\001qsp.aged";
/ the user the query is being run as
usermark:`$"\001qsp.user";
/ the policy clock, as a timestamp
nowmark:`$"\001qsp.now";

export:([chk;prefix;fault;isfault;clean;described;selop;updop;ascop;descop;getc;setc;lit;isfn;isquery;
  hasquery;joins;isjoin;namerefs;basequeries;basetables;hasfilehandle;agedmark;usermark;nowmark]);
