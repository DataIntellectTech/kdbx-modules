/ di.qsp.order - where the row filter goes in a where clause
/ q applies constraints left to right, and that matters twice over:
/   correctness  a user constraint evaluated before the policy filter sees rows the user may
/                not. Harmless for size>10; not for "where size=max size", which returns
/                nothing exactly when the largest trade is hidden - and so discloses that it is
/   performance  on an HDB the partition constraint must lead or every partition is read, and an
/                indexed constraint next is the difference between a lookup and a scan
/ both are satisfied by moving only constraints that cannot aggregate - a plain comparison of a
/ column with something that does not depend on other rows of the table. Such a constraint yields
/ the same boolean vector however many rows precede it, so moving it changes the speed and never
/ the answer
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

eqops:fns.resolve each `$("=";"~";"in");
sortops:eqops,fns.resolve each `$("<";"<=";">";">=";"within");
moveops:sortops,fns.resolve each `$("<>";"like");
/ operators that narrow a partition column to a range. date<>x is movable, but reads every
/ partition but one
pruneops:sortops;

/ which operators can actually use each attribute's index
indexops:`p`u`g`s!(eqops;eqops;eqops;sortops);

/ the partition column always leads
rankpart:0;
/ simple, but no index to exploit
rankplain:50;
/ could aggregate - never moved
rankfixed:900;

movable:{[ti;c]
  / (op;column;value), where value names no column of this table and holds no nested select. A
  / name that is not a column - a global the policy refers to - is fine, and must be, or it
  / would drag the whole policy filter to the front of the where clause and cost partition
  / pruning
  if[0h<>type c;:0b];
  if[3<>count c;:0b];
  if[not any normop[first c]~/:moveops;:0b];
  if[-11h<>type c 1;:0b];
  if[tree.hasquery c 2;:0b];
  if[`i in (c 1),tree.namerefs c 2;:0b];
  :0=count (tree.namerefs c 2) inter ti`columns;
  };

crank:{[ti;ar;c]
  / where constraint c ranks: lower runs first
  if[not movable[ti;c];:rankfixed];
  if[(c 1)~ti`partition;:rankpart];
  a:ti[`attributes]c 1;
  if[not a in ar;:rankplain];
  / the wrong operator for this index
  if[not any normop[first c]~/:indexops a;:rankplain];
  :1+ar?a;
  };

sort:{[ti;ar;l;isuser]
  / stable rank sort. Within a rank the policy's constraints come before the user's: it costs
  / nothing and limits the damage if a constraint is ever misclassified as movable. Within an
  / origin, the written order stands
  if[2>count l;:l];
  :l iasc (1000000*crank[ti;ar] each l)+(1000*isuser)+til count l;
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
/ date=2010.01.01" prunes, "where date=max date" cannot - and an operator that narrows
prunesby:{[ti;c] :$[movable[ti;c];((c 1)~ti`partition)&any normop[first c]~/:pruneops;0b];};

/ does this constraint list prune the partition column? q narrows the partitions it reads only
/ by the constraint that leads: "where size=max size, date=d" reads every partition, and so
/ does "where sym=`a, date=d". place puts a movable partition constraint first, so the
/ constraint that leads is the one to test
prunes:{[ti;cons] :$[null ti`partition;1b;0=count cons;0b;prunesby[ti] first cons];};

export:([normop;movable;place;prunes]);
