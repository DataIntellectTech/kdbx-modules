/ library for sending async messages from a client process

send:{[w;h;q]
  / build the query to send
  tosend:$[w; ({[q] @[neg .z.w;@[{[q] (1b;value q)};q;{(0b;"error: server fail:",x)}];()]};q);
              ({[q] @[neg .z.w;@[{[q] value q};q;{"error: server fail:",x}];()]};q)];
  / error trapping sending the query down the handle followed by an async flush
  .[{x@y; x(::);1b};(h;tosend);0b]}

deferred:{[handles;query]
  / for sending deferred synchronous message to a list of handles
  sent:.z.m.send[1b;;query] each handles:neg abs handles,();
  / block and wait for the results
  res:{$[y;@[x;(::);(0b;"error: comm fail: handle closed while waiting for result")];(0b;"error: comm fail: failed to send query")]}'[abs handles;sent];
  / return results
  (res[;0];res[;1])}


postback:{[handles;query;postback] 
  / for sending asynchronous postback message to a list of handles where the message is wrapped in the function postback
  send[0b;;({[q;p] (p;@[value;q;{"error: server fail: ",x}])};query;postback)] each handles:neg abs handles,()}

broadcastdeferred:{[handles;query]
  / for sending deferred synchronous message to a list of handles via async broadcast
  tosend:({[q] @[neg .z.w;@[{[q] (1b;value q)};q;{(0b;"error: server fail:",x)}];()]};query);
  sent:.[{-25!(x;y); x(::);1b};(handles;tosend);{(0b;"error: ",x)}];
  if[not first sent;:sent];
  / block and wait for the results
  res:{$[y;@[x;(::);(0b;"error: comm fail: handle closed while waiting for result")];(0b;"error: comm fail: failed to send query")]}'[abs handles;sent];
  / return results
  (res[;0];res[;1])}

broadcastpostback:{[handles;query;postback]
  / for sending asynchronous postback message to a list of handles via async broadcast where the message is wrapped in the function postback
  q:({[q;p] (p;@[value;q;{"error: server fail: ",x}])};query;postback);
  tosend:({[q] @[neg .z.w;@[{[q] value q};q;{"error: server fail: ",x}];()]};q);
  / error trapping sending the query down the handle followed by an async flush
  .[{-25!(x;y); x(::);(count x)#1b};(handles;tosend);{(y#0b;"error: ",x)}[;count handles]]}