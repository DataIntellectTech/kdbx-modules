/ di.html - websocket pub/sub and html page serving

/ list of table names registered for pub/sub
subtables:`symbol$();

/ subscriber list per table: each entry is (handle; sym-filter)
subs:()!();

/ modifier function per table: transforms data before sending to subscriber
modifier:()!();

/ cache of resolved ip addresses: int -> symbol
ipacache:(`int$())!`symbol$();

/ home directory for html files - set by init
homedir:"";

/ logging functions - required injected deps, wired by init via .z.m

/ converts a list of timestamps or dates to iso 8601 strings e.g. "2024-01-02T12:00:00Z"
jstsiso8601:{[x] {("-" sv "." vs string `date$x),"T",string[`second$x],"Z"} each x};

/ converts a list of dates to javascript epoch milliseconds
/ kdb dates are days since 2000-01-01; 10957 is the day offset from 1970-01-01 to 2000-01-01
jstsfromd:{[x] "j"$86400000 * 10957 + `long$x};

/ converts a list of time, second, or minute values to milliseconds since midnight
jstsfromt:{[x] "j"$"t"$x};

/ converts a list of months to javascript epoch milliseconds via the first day of each month
jstsfromm:{[x] jstsfromd `date$x};

/ maps kdb type shorts to their javascript converter function
/ types not listed here are left unchanged by jsformat
typemap:12 13 14 16 17 18 19h!(jstsiso8601;jstsfromm;jstsfromd;jstsfromt;jstsfromt;jstsfromt;jstsfromt);

jsformat:{[tbl]
  / applies the correct javascript converter to each column of a table that needs it
  / columns whose type is not in the typemap are passed through unchanged (via ::)
  coldict:flip 0!tbl;
  k:key coldict;
  colvals:value coldict;
  converters:typemap type each colvals;
  :flip k!converters@'colvals;
  };

updformat:{[msgtype;msgdata]
  / wraps an upd message into a name/data dictionary with javascript-formatted table data
  formatteddata:(key msgdata)!(msgdata`tablename;jsformat msgdata`tabledata);
  :(`name`data)!(msgtype;formatteddata);
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

replace:{[str;findreplace]
  / applies each find->replace pair to the string in sequence using ssr
  :(ssr/)[str;string key findreplace;value findreplace];
  };

ipa:{[ipint]
  / resolves an ip address integer to a hostname symbol, caching results
  / tries .Q.host first; falls back to converting the ip bytes manually if that fails
  if[not `~r:ipacache ipint;:r];
  hostname:.Q.host ipint;
  r:$[`~hostname;`$"."sv string "i"$0x0 vs ipint;hostname];
  .z.m.ipacache:@[ipacache;ipint;:;r];
  :r;
  };

/ returns the current listen port as a string
getport:{[] string system "p"};

execdict:{[inputdict]
  / extracts the func key and any additional args from a dictionary and calls the function
  / args are passed to the function in the order the keys appear after func
  if[not `func in key inputdict;'"no func in dictionary"];
  f:value inputdict`func;
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
  .z.m.modifier:modifier,new!(count new)#{-8!.j.j updformat["upd";`tablename`tabledata!(x 1;x 2)]};
  if[count new;.z.m.lginfo[`html;"registered tables: ",", " sv string new]];
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

wssub:{[tbl]
  / subscribes via websocket, no return value
  sub[tbl;`];
  };

end:{[eodval]
  / broadcasts end-of-day message to all subscriber handles across all tables
  (neg union/[subs[;;0]])@\:(`.u.end;eodval);
  };

readpage:{[filename]
  / reads an html file from the configured home directory and returns it as a string
  / returns a "not found" message string if the file does not exist
  p:homedir,"/",filename;
  r:@[read1;`$":",p;""];
  if[not count r;.z.m.lgwarn[`html;p,": not found"]];
  :$[count r;"c"$r;p,": not found"];
  };

readpagereplaceHP:{[filename]
  / reads a page and replaces MYKDBSERVER and MYKDBPORT tokens with live server values
  :replace[readpage filename;`MYKDBSERVER`MYKDBPORT!("\"",(string ipa .z.a),"\"";getport[])];
  };

evaluate:{[inputdict]
  / safely calls execdict on the input, logging then re-throwing any errors with context
  :@[execdict;inputdict;{[d;e] m:"failed to execute ",(-3!d)," : ",e;.z.m.lgerr[`html;m];'m}[inputdict]];
  };

init:{[config;deps]
  / sets up module state from config and registers websocket handlers
  / log dep is required; handlers dep is optional

  / log dependency is required - guard that deps is a dict, log key is present and not (::)
  logdict:$[99h=type deps;$[(`log in key deps)and not(::)~deps`log;deps`log;()!()];()!()];
  if[not count logdict;
    '"di.html: log dependency is required; pass `info`warn`error functions - see di.log for a default implementation";
    ];
  .z.m.lginfo:logdict`info;
  .z.m.lgwarn:logdict`warn;
  .z.m.lgerr:logdict`error;

  / store config
  .z.m.homedir:config`homedir;

  / register .h content type handlers - protected in case not available in kdb-x
  @[{.h.tx[`non]:{enlist x};.h.ty[`non]:"text/html"};`;{[e]}];

  / register handlers via dep if provided
  if[`handlers in key deps;
    deps[`handlers][`register][`.z.ws;`html.ws;wshandler];
    deps[`handlers][`register][`.z.wc;`html.close;closehandle];
    :()];

  / no handlers dep: assign directly, wrapping any existing .z.wc to preserve it
  .z.ws:wshandler;
  .z.wc:@[value;`.z.wc;{{}}];
  .z.wc:{[existing;h] closehandle h; existing h}[.z.wc;];

  .z.m.lginfo[`html;"initialised with homedir: ",homedir];
  };
