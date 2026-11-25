/ di.qsp.core.order - where the row filter goes in a where clause
/ q applies constraints left to right, and that matters twice over:
/   correctness  a user constraint evaluated before the policy filter sees rows the user may
/                not. Harmless for size>10; not for "where size=max size", which returns
/                nothing exactly when the largest trade is hidden - and so discloses that it is
/   performance  on an HDB the partition constraint must lead or every partition is read, and an
/                indexed constraint next is the difference between a lookup and a scan
/ both are satisfied by moving only constraints that cannot aggregate - a plain comparison of a
/ column with something that does not depend on other rows of the table, or an and, or or not of
/ such comparisons. Such a constraint yields the same boolean for each row however many rows
/ precede it, so moving it changes the speed and never the answer. Two things make a comparison
/ depend on the other rows after all, and neither is moved:
/   ~         matches the whole column, and returns one boolean: "where s~`a`b`zz", run before the
/             row filter, says whether a hidden row's s is `zz
/   a list    "where s=`a`b`a" compares row by row, and signals 'length unless the list is exactly as
/             long as the rows in front of it - moved before the row filter, that counts the
/             hidden rows. So a comparison moves only with one value on its right (two for
/             within, one pattern for like); a value computed from the user's own expression is
/             checked as it runs (fns.scalar and friends, placed by guardvalues)
/ every function takes ti, a table's info (policy.info), and nothing else of the policy: ordering
/ is a pure function of the table and the constraints

tree:use`..tree;
fns:use`..fns;

/ q renders a<>b, a<=b and a>=b as (';not;=) and friends. Map each back to the operator it stands
/ for - and the walker may already have substituted not for its guarded wrapper, so both shapes
/ are recognised
compform:{[o] :first first tree.getc (parse"select from qspprobe where a",o," b")2;};
negation:{[o] :((compform o)2;fns.resolve`$o);};
negations:@[{negation each ("<>";"<=";">=")};::;{()}];
nots:(fns.resolve`not;fns.notsafe);

normop:{[h]
  / the operator a constraint head stands for
  if[0h<>type h;:h];
  if[3<>count h;:h];
  if[not (h 0)~fns.compose;:h];
  if[not any (h 1)~/:nots;:h];
  :$[(count negations)>i:negations[;0]?h 2;negations[i;1];h];
  };

eqops:fns.resolve each `$("=";"in");
sortops:eqops,fns.resolve each `$("<";"<=";">";">=";"within");
moveops:sortops,fns.resolve each `$("<>";"like");
/ the comparisons q makes row by row against a list on the right - all but in
scalarops:fns.resolve each `$("=";"<";"<=";">";">=";"<>");
withinop:fns.resolve`within;
likeop:fns.resolve`like;
/ and, or: a constraint built from movable ones is movable
logicops:fns.resolve each `$(1#"&";1#"|");
/ operators that bound a partition column on both sides, so q reads a known set of partitions.
/ A one-sided range is open: date>x or date<cutoff read every partition from x, or up to the
/ cutoff, and on a database of years that is all of them. date<>x reads all but one
pruneops:eqops,fns.resolve each enlist`within;

/ which operators can actually use each attribute's index
indexops:`p`u`g`s!(eqops;eqops;eqops;sortops);

/ the partition column always leads, and a constraint that bounds it leads that: q prunes only by
/ the first constraint, so "date<cutoff, date=d" reads every partition before the cutoff, and
/ "date=d, date<cutoff" reads one. Either order gives the same rows
rankpart:0;
/ any other movable constraint on the partition column - a one-sided range such as an embargo
rankpartopen:1;
/ simple, but no index to exploit
rankplain:50;
/ could aggregate - never moved
rankfixed:900;

/ a constraint's right side as written: (1b;the value) for literal data - parse quotes a symbol or
/ a list in a one-item list - or (0b;::) for an expression q computes as it runs
literal:{[v]
  if[(0h=type v)&1=count v;:(1b;first v)];
  if[11h=type v;:$[1=count v;(1b;first v);(0b;::)]];
  if[(0h=type v)|-11h=type v;:(0b;::)];
  :(1b;v);
  };

/ is literal value v the shape op compares one row at a time with: one value, a pair for within,
/ a pattern for like
oneshape:{[op;v]
  if[any op~/:scalarops;:0>type v];
  if[op~withinop;:$[0h=type v;(2=count v)&all 0>type each v;(0<type v)&2=count v]];
  if[op~likeop;:(type v) in -10 10h];
  :1b;
  };

/ is c an and, or or not of other constraints?
iscompound:{[c]
  if[0h<>type c;:0b];
  if[(3=count c)&any (first c)~/:logicops;:1b];
  :(2=count c)&any (first c)~/:nots;
  };

movable:{[ti;c]
  / (op;column;value), where value names no column of this table and holds no nested select, or
  / an and, or or not of movable constraints. A name that is not a column - a global the policy
  / refers to - is fine, and must be, or it would drag the whole policy filter to the front of
  / the where clause and cost partition pruning
  if[0h<>type c;:0b];
  if[iscompound c;:all movable[ti] each 1_c];
  if[3<>count c;:0b];
  op:normop first c;
  if[not any op~/:moveops;:0b];
  if[-11h<>type c 1;:0b];
  if[tree.hasquery c 2;:0b];
  if[`i in (c 1),tree.namerefs c 2;:0b];
  l:literal c 2;
  if[l 0;if[not oneshape[op;l 1];:0b]];
  :0=count (tree.namerefs c 2) inter ti`columns;
  };

/ the check a computed right side gets, by operator
guardfor:{[op] :$[any op~/:scalarops;fns.scalar;op~withinop;fns.pair;op~likeop;fns.pattern;(::)];};

guardvalue:{[ti;c]
  / one of the user's constraints, its computed right side checked as it runs - where the
  / constraint could be moved. One that reads other columns stays where it is written, and is
  / meant to compare row by row: size>2*price
  if[not movable[ti;c];:c];
  if[iscompound c;:(enlist first c),guardvalue[ti] each 1_c];
  if[(::)~g:guardfor normop first c;:c];
  if[first literal c 2;:c];
  :@[c;2;:;(g;c 2)];
  };

/ the user's constraints on table ti, each movable one's computed right side checked as it runs:
/ a list where one value belongs would compare row by row, and moved ahead of the row filter it
/ would count the hidden rows
guardvalues:{[ti;cons] :guardvalue[ti] each cons;};

crank:{[ti;ar;c]
  / where constraint c ranks: lower runs first
  if[not movable[ti;c];:rankfixed];
  if[iscompound c;:rankplain];
  if[(c 1)~ti`partition;:$[any normop[first c]~/:pruneops;rankpart;rankpartopen]];
  a:ti[`attributes]c 1;
  if[not a in ar;:rankplain];
  / the wrong operator for this index
  if[not any normop[first c]~/:indexops a;:rankplain];
  :2+ar?a;
  };

sort:{[ti;ar;l;isuser]
  / stable rank sort. Within a rank the policy's constraints come before the user's: it costs
  / nothing and limits the damage if a constraint is ever misclassified as movable. Within an
  / origin, the written order stands
  if[2>count l;:l];
  :l iasc ([]r:crank[ti;ar] each l;u:isuser;i:til count l);
  };

place:{[ti;cfg;c;pf]
  / merge the policy filter pf into the user's constraints c
  /   `auto  rank as above
  /   `first policy filter first, user's order untouched after it
  /   `last  user's constraints first - fastest, and permits the inference channel described at
  /          the top of this file
  if[0<count pf;
    if[`first=cfg`placement;:pf,c];
    if[`last=cfg`placement;:c,pf];
    / a policy filter that is not itself movable must run before anything the user wrote, or
    / its own meaning changes
    if[not all movable[ti] each pf;:pf,c]];
  n:count[c]^first where not movable[ti] each c;
  :sort[ti;cfg`attributerank;(n#c),pf;(n#1),count[pf]#0],n _ c;
  };

/ does constraint c prune the partition column? The same test as movable - "where
/ date=2010.01.01" prunes, "where date=max date" cannot - and an operator that bounds it
prunesby:{[ti;c] :$[movable[ti;c];$[iscompound c;0b;((c 1)~ti`partition)&any normop[first c]~/:pruneops];0b];};

/ does this constraint list prune the partition column? q narrows the partitions it reads only
/ by the constraint that leads: "where size=max size, date=d" reads every partition, so does
/ "where sym=`a, date=d", and "where date>=a, date<=b" reads every partition from a. place puts
/ a bounding partition constraint first, so the constraint that leads is the one to test
prunes:{[ti;cons] :$[null ti`partition;1b;0=count cons;0b;prunesby[ti] first cons];};

export:([normop;movable;place;prunes;prunesby;guardvalues]);
