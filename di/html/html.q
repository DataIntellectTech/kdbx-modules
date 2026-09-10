/ di.html - websocket pub/sub and html page serving

/ list of table names registered for pub/sub
subtables:`symbol$();

/ subscriber list per table: each entry is (handle; sym-filter)
subs:()!();

/ modifier function per table: transforms data before sending to subscriber
modifier:()!();

/ flag so direct .z handler wiring happens only once across repeated init calls
zwired:0b;

normlog:{[logdict]
  / normalise a log dict: if it looks like a kx.log instance (has getlvl/sinks/fmts keys),
  / wrap each level into a dyadic {[c;m]} function that embeds the context symbol into the message
  $[any `getlvl`sinks`fmts in key logdict;
    `info`warn`error!(
      {[fn;c;m] fn[string[c],": ",m]}[logdict`info;];
      {[fn;c;m] fn[string[c],": ",m]}[logdict`warn;];
      {[fn;c;m] fn[string[c],": ",m]}[logdict`error;]);
    logdict];
  };

jstsiso8601:{[x]
  / converts a list of timestamps or datetimes to iso 8601 strings e.g. "2024-01-02T12:00:00Z"
  / vectorised: stringifies the date and time parts in bulk rather than per element; nulls return ""
  i:where 10=count each d:string `date$x;
  r:(count d)#enlist "";
  if[not count i;:r];
  dd:d i;
  dd[;4 7]:"-";
  r[i]:dd,'("T",/:string `second$x i),\:"Z";
  :r;
  };

/ converts a list of dates to javascript epoch milliseconds
/ kdb dates are days since 2000-01-01; 10957 is the day offset from 1970-01-01 to 2000-01-01
jstsfromd:{[x] "j"$86400000 * 10957 + `long$x};

/ converts a list of time, second, or minute values to milliseconds since midnight
jstsfromt:{[x] "j"$"t"$x};

/ converts a list of months to javascript epoch milliseconds via the first day of each month
jstsfromm:{[x] jstsfromd `date$x};

/ maps kdb type shorts to their javascript converter function
/ types not listed here are left unchanged by jsformat
typemap:12 13 14 15 16 17 18 19h!(jstsiso8601;jstsfromm;jstsfromd;jstsiso8601;jstsfromt;jstsfromt;jstsfromt;jstsfromt);

jsformat:{[tbl]
  / applies the correct javascript converter to each column of a table that needs it
  / columns whose type is not in the typemap are passed through unchanged (via ::)
  coldict:flip 0!tbl;
  k:key coldict;
  colvals:value coldict;
  converters:typemap type each colvals;
  :flip k!converters@'colvals;
  };

dataformat:{[msgtype;msgdata]
  / wraps a message into a name/data dictionary, javascript-formatting each table in msgdata
  / msgdata is a list or dictionary of tables - used by host data functions requested from the front end
  :(`name`data)!(msgtype;jsformat each msgdata);
  };

/ filter applied before sending data to a subscriber - returns full table (no filtering)
sel:{[tbl;syms] tbl};

del:{[tbl;handle]
  / removes a handle from the subscriber list for a table
  / if handle is not found, ? returns count of list and drop has no effect
  idx:subs[tbl;;0]?handle;
  .z.m.subs:@[subs;tbl;_;idx];
  };

add:{[tbl;syms]
  / adds the current handle to the subscriber list for a table
  / if already subscribed, updates the sym filter by taking union with new syms
  / if not subscribed, appends a new (handle; syms) pair to the list
  / returns (tablename; current data) so the subscriber can initialise their local copy
  i:subs[tbl;;0]?.z.w;
  .z.m.subs:$[(count subs tbl)>i;
    .[subs;(tbl;i;1);union;syms];
    @[subs;tbl;,;enlist(.z.w;syms)]
    ];
  :(tbl;$[99=type v:value tbl;sel[v;syms];@[0#v;`sym;`g#]]);
  };

closehandle:{[handle]
  / removes the given handle from all subscriber lists when a connection closes
  del[;handle] each subtables;
  };

execdict:{[inputdict]
  / extracts the func key and any additional args from a dictionary and calls the function
  / args are passed to the function in the order the keys appear after func
  / checks the module funcmap first (module-local functions), then falls back to value for globals
  if[not `func in key inputdict;'"no func in dictionary"];
  fname:`$inputdict`func;
  f:$[fname in key funcmap;
    funcmap fname;
    @[value;inputdict`func;{'"unknown function: ",x}]];
  args:value inputdict _ `func;
  :$[1=count key inputdict;f @ 1;f . args];
  };

/ websocket message handler - module-level so it carries the module context for evaluate
wshandler:{neg[.z.w] -8!.j.j[evaluate[.j.k -9!x]];};

addtables:{[tablelist]
  / registers a list of tables for pub/sub and sets their default modifier
  / can be called multiple times; already-registered tables are ignored
  tablelist,:();
  new:tablelist except subtables;
  .z.m.subtables:subtables,new;
  .z.m.subs:subs,new!(count new)#();
  / default modifier applies jsformat then sends kdb+ IPC binary wrapping a json string (c.js binary protocol)
  .z.m.modifier:modifier,new!(count new)#{-8!.j.j `name`data!("upd";`tablename`tabledata!(x 1;jsformat x 2))};
  if[count new;.z.m.log[`info][`di.html;"registered tables: ",", " sv string new]];
  };

pub:{[tbl;data]
  / publishes data to all current subscribers of a table
  / applies the table modifier before sending (default modifier json-encodes the data)
  {[tbl;data;s]
    if[count data:sel[data;s 1];
      (neg first s) modifier[tbl]@(`upd;tbl;data)];
    }[tbl;data] each subs tbl;
  };

sub:{[tbl;syms]
  / subscribes the current handle to a table with an optional sym filter
  / pass backtick as tbl to subscribe to all registered tables
  / removes any existing subscription for this handle before re-adding
  if[tbl~`;:sub[;syms] each subtables];
  if[not tbl in subtables;'tbl];
  del[tbl;.z.w];
  :add[tbl;syms];
  };

setmodifier:{[tbl;fn]
  / sets a custom modifier function for tbl; fn receives (`upd;tbl;data) and must return bytes or a string to send
  if[not tbl in subtables;'tbl];
  .z.m.modifier:@[modifier;tbl;:;fn];
  };

evaluate:{[inputdict]
  / safely calls execdict on the input, logging then re-throwing any errors with context
  :@[execdict;inputdict;{[d;e] m:"failed to execute ",(-3!d)," : ",e;.z.m.log[`error][`di.html;m];'"di.html: ",m}[inputdict]];
  };

/ module-local functions callable via websocket evaluate
/ execdict checks here first before falling back to value for global lookups
funcmap:`sub`addtables`pub`dataformat!(sub;addtables;pub;dataformat);

init:{[deps]
  / initialise the module; deps must contain a log key
  / deps: dict with `log key -> dict with at minimum `info!{[c;m]} (dyadic: ctx symbol, msg string)
  / kx.log instances are normalised automatically via normlog
  / wires .z.ws/.z.wc/.z.pc handlers once; .h.HOME set from KDBHTML env var (else "html")
  if[99h<>type deps;
    '"di.html: deps must be a dict with `log key"];
  if[not `log in key deps;
    '"di.html: log dependency is required; pass at minimum `info!{[c;m]} keyed on `log"];
  if[99h<>type deps`log;
    '"di.html: log value must be a dict; pass at minimum `info!{[c;m]}"];
  if[not `info in key deps`log;
    '"di.html: log dict must have at minimum an `info key; got: ",(", " sv string key deps`log)];
  .z.m.log:normlog deps`log;
  hd:$[count e:getenv`KDBHTML;e;"html"];
  / .h.HOME lets the default http handler serve static assets; set from KDBHTML env var (else "html")
  @[{.h.HOME:x;.h.tx[`non]:{enlist x};.h.ty[`non]:"text/html"};hd;{[e]}];
  .z.m.log[`info][`di.html;"initialised"];
  / wire handlers once; wrap any existing .z.wc/.z.pc to preserve them
  if[zwired;:()];
  .z.ws:wshandler;
  .z.wc:{[existing;h] closehandle h; existing h}[@[value;`.z.wc;{{[x]}}];];
  .z.pc:{[existing;h] closehandle h; existing h}[@[value;`.z.pc;{{[x]}}];];
  .z.m.zwired:1b;
  };
