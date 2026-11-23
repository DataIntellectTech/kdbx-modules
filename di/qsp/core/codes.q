/ di.qsp.core.codes - every refusal as a code, a kind and a subject
/   classify["qsp: unknown or not-permitted column: pnl"]
/     -> `code`kind`subject!(`columns.unknown;`permission;"pnl")
/ a refusal's text is written for a person. A program that acts on one - an agent's tooling
/ offering a fix, a dashboard counting refusals - needs it as data that does not change when the
/ wording does. The code is family.reason, where the family is the id of the rule that explains
/ it (api/init.q's ruletable) or, for refusals no rule covers, the thing refused: users, rate, q
/ (q's own errors), api, transport. The kind says what sort of no it is:
/   permission  access was withheld: a column, table, function, user, or a form refused because
/               it could reach something the caller may not. Nothing should suggest a way round it
/   shape       the query could run in another form that reads exactly the same: a bracket, a
/               name, an order of constraints
/   limit       a bound on the work or the result
/   runtime     q could not evaluate a query qsp had permitted
/ The subject is the name or the rendered expression the refusal is about, taken from the
/ message: it never says anything the message does not. A message no pattern knows is
/ refusals.other, kind permission - the kind that invites no workaround

/ one row per pattern, first match wins: (code; kind; how; pattern; subject rule)
/   how      `prefix: the message starts with the pattern; `infix: it contains it
/   subject  `after: what follows the pattern, to the first " - ", " (" or ", "; `before: what
/            precedes the pattern; `paren: inside the first (...); `none
patterns:flip `code`kind`how`pattern`subject!flip (
  (`users.outofscope;      `permission;`infix; " may not run queries as ";               `after);
  (`users.unknown;         `permission;`prefix;"not a user of this policy: ";             `after);
  (`rate.limit;            `limit;     `prefix;"rate limit: ";                            `none);
  (`rows.mingroup;         `permission;`prefix;"mingroup: ";                              `none);
  (`columns.shadowed;      `shape;     `infix; " is a column this query names, but that name is taken"; `before);
  (`columns.notinscope;    `shape;     `infix; " is not in scope here";                   `before);
  (`columns.unknown;       `permission;`prefix;"unknown or not-permitted column: ";       `after);
  (`columns.reserved;      `shape;     `infix; "so they cannot name a column";            `none);
  (`columns.reserved;      `shape;     `infix; "so it cannot name a column";              `none);
  (`columns.part;          `shape;     `infix; " is not a part q takes after a dot";      `none);
  (`language.invalid;      `shape;     `prefix;"not valid q (";                           `paren);
  (`language.head;         `shape;     `prefix;"expression head is not a function: ";     `after);
  (`nesting.stray;         `shape;     `prefix;"a where after a value: ";                 `stray);
  (`nesting.by;            `shape;     `prefix;"by goes before from in q-SQL";             `none);
  (`tables.unknown;        `permission;`prefix;"unknown or non-permissioned table: ";     `after);
  (`tables.nocolumns;      `permission;`prefix;"no column access granted on table: ";     `after);
  (`tables.asvalue;        `shape;     `infix; " can only be used as the table of a select"; `before);
  (`tables.asvalue;        `shape;     `prefix;"a table name cannot be used as data";     `none);
  (`tables.expression;     `shape;     `prefix;"unsupported table expression";            `none);
  (`tables.expression;     `shape;     `prefix;"a join in the table position";            `none);
  (`tables.expression;     `shape;     `prefix;"the columns this expression projects cannot be known"; `none);
  (`tables.expression;     `shape;     `prefix;"a table expression must be over a nested select"; `none);
  (`partition.fullscan;    `shape;     `prefix;"full table scan: ";                       `word);
  (`partitioned.wrap;      `shape;     `prefix;"update/delete on a partitioned table must wrap a select"; `none);
  (`maxpartitions.toomany; `limit;     `prefix;"too many partitions: ";                   `word);
  (`writes.wrap;           `shape;     `prefix;"update/delete must wrap a select";        `none);
  (`writes.inplace;        `permission;`prefix;"in-place update/delete is not permitted"; `none);
  (`results.maxrows;       `limit;     `prefix;"result exceeds the maximum permitted row count"; `none);
  (`size.toobig;           `limit;     `prefix;"result exceeds the maximum permitted size"; `none);
  (`size.toobig;           `limit;     `prefix;"too big to run: ";                        `none);
  (`depth.toodeep;         `limit;     `prefix;"expression is nested too deeply";         `none);
  (`functions.notpermitted;`permission;`prefix;"function not permitted: ";                `after);
  (`functions.notpermitted;`permission;`prefix;"call to ";                                `word);
  (`functions.unknown;     `permission;`infix; " is neither a permitted function nor a column in scope"; `before);
  (`functions.data;        `permission;`prefix;"a function cannot be written as data";    `none);
  (`functions.data;        `permission;`prefix;"only q's simple functions can be applied"; `none);
  (`functions.data;        `permission;`prefix;"data holding a function";                 `none);
  (`symbols.filehandle;    `permission;`prefix;"file handle symbols are not permitted";   `none);
  (`symbols.enum;          `permission;`infix; " casts to an enumeration";                `before);
  (`symbols.applied;       `permission;`infix; " cannot be applied";                      `before);
  (`comparisons.arity;     `shape;     `prefix;"a comparison in a where clause takes one value"; `none);
  (`comparisons.arity;     `shape;     `prefix;"like takes one pattern";                  `none);
  (`comparisons.arity;     `shape;     `prefix;"within takes two values";                 `none);
  (`sort.form;             `shape;     `prefix;"a sort must be by a column";              `none);
  (`sort.form;             `shape;     `prefix;"a sort is only supported on select";      `none);
  (`joins.keyed;           `shape;     `infix; " requires a keyed right-hand table";      `none);
  (`joins.key;             `shape;     `infix; " side has no column ";                    `none);
  (`joins.wj;              `shape;     `prefix;"wj aggregates";                           `none);
  (`functional.form;       `shape;     `prefix;"write the query as select";               `none);
  (`functional.form;       `shape;     `prefix;"dictionary expressions are not permitted"; `none);
  (`functional.form;       `shape;     `prefix;"unsupported ";                            `none);
  (`transport.refused;     `permission;`infix; " access is not permitted";                `none);
  (`api.call;              `shape;     `prefix;"unknown api call";                        `none);
  (`api.call;              `shape;     `prefix;"api call ";                               `none);
  (`q.stop;                `runtime;   `prefix;"stop: ";                                  `none);
  (`q.wsfull;              `runtime;   `prefix;"wsfull: ";                                `none);
  (`q.unknown;             `runtime;   `prefix;"the database would not evaluate this query"; `none));

/ q's own errors, which evalerror passes on as they are: one word, sometimes with detail after it
qerrors:`type`length`rank`nyi`domain`limit`par`os`mismatch`assign`stack`value`noamend`splay`part;

/ the text of message m after "qsp: ", and after the marker byte a fault carries
body:{[m]
  m:$[10h=type m;m;-11h=type m;string m;""];
  if[count m;if["\001"=first m;m:1_m]];
  :$["qsp: "~5#m;5_m;m];
  };

/ text up to the first separator a message puts after its subject
cut1:{[a]
  n:min (count a),raze {[a;sep] a ss sep}[a] each (" - ";" (";", ");
  :n#a;
  };

/ where pattern row r matches message body b: its start, or 0N for no match
matchat:{[b;r] p:r`pattern; :$[`prefix~r`how;$[p~(count p)#b;0;0N];first b ss p];};

/ the subject of body b, matched by pattern row r at position i
subject:{[b;r;i]
  s:r`subject;
  if[s~`before;:i#b];
  a:(i+count r`pattern)_b;
  if[s~`after;:cut1 a];
  if[s~`word;:first " " vs a];
  if[s~`stray;:(first a ss " where")#a];
  if[s~`paren;:(first a ss ")")#a];
  :"";
  };

classify:{[m]
  / message m - a refusal, as signalled or logged - as code, kind and subject
  b:body m;
  if[0=count b;:`code`kind`subject!(`q.unknown;`runtime;"")];
  i:matchat[b] each patterns;
  j:first where not null i;
  if[not null j;r:patterns j;:`code`kind`subject!(r`code;r`kind;subject[b;r;i j])];
  w:first " " vs b;
  if[(`$w) in qerrors;:`code`kind`subject!(`$"q.",w;`runtime;"")];
  :`code`kind`subject!(`refusals.other;`permission;"");
  };

/ the codes and their kinds, as published: one row per code
table:{[] :distinct flip `code`kind!(patterns`code;patterns`kind);};

export:([classify;table;body]);
