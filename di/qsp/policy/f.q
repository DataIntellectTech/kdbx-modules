/ di.qsp.policy.f - row filter builders, so a policy is not written as raw parse trees
/ each returns one constraint; a grant's row filter is a list of them, ANDed
/   qsp.f.isin[`account;`A1`A2]          account in `A1`A2
/   qsp.f.aged[`time;0D00:15]            only rows at least 15 minutes old
/   (in;`sym;(`allowedsyms;qsp.USER))    a lookup evaluated as the query runs

tree:use`...core.tree;
fns:use`...core.fns;

eq:{[c;v] :((=);c;tree.lit v);};
ne:{[c;v] :((<>);c;tree.lit v);};
lt:{[c;v] :((<);c;tree.lit v);};
le:{[c;v] :((<=);c;tree.lit v);};
gt:{[c;v] :((>);c;tree.lit v);};
ge:{[c;v] :((>=);c;tree.lit v);};
isin:{[c;v] :(in;c;tree.lit v);};
notin:{[c;v] :(fns.notsafe;(in;c;tree.lit v));};
inrange:{[c;v] :(within;c;tree.lit v);};
matches:{[c;v] :(like;c;tree.lit v);};
both:{[a;b] :((&);a;b);};
either:{[a;b] :((|);a;b);};

aged:{[c;span]
  / only rows at least span old on column c, measured against the policy's clock. The cutoff is
  / computed per query and cast to the column's type, and reaches the query as a plain literal -
  / so it ranks like any comparison, and explain and the audit log show the cutoff applied. Aging
  / the partition column turns the embargo into partition pruning, in whole days:
  /   qsp.f.aged[`date;0D]             nothing from today
  /   qsp.f.aged[`time;0D00:15]        on a timestamp: exactly 15 minutes behind
  / see docs/time.md
  tree.chk[-11h=type c;"f.aged needs a column name"];
  tree.chk[-12h=type @[{.z.p-x};span;(::)];"f.aged needs a timespan, e.g. 0D00:15"];
  :((<);c;(tree.agedmark;c;span));
  };

export:([eq;ne;lt;le;gt;ge;isin;notin;inrange;matches;both;either;aged]);
