/ library for sending async messages from a client process

flushhandles:{[handles]
  / push each handle's outgoing async queue onto the wire.
  / -25! only QUEUES the broadcast - q sends it when the process next returns to its main loop, so a
  / caller that keeps working (an rdb rolling the day) reports success while nothing has left the
  / process, and a caller that exits first never sends it at all. measured: postback to an idle peer
  / followed by a 2s in-script sleep never reached the peer without this.
  / NB the flush must be per handle. neg[handles][] on the LIST is an INDEX, not a flush - which is
  / exactly what the old x(::) here was, silently doing nothing (measured). and x(::) on an ATOM
  / handle is worse: it is a sync send of :: that no peer replies to, so it blocks forever (measured)
  {neg[x][]} each handles;
  }

deferred:{[handles;query]
  / for sending deferred synchronous message to a list of handles via async broadcast
  tosend:({[q] @[neg .z.w;@[{[q] (1b;value q)};q;{(0b;"error: server fail:",x)}];()]};query);
  / flush so EVERY peer starts work now. without it only the handle we block on below is pushed out,
  / and the rest are not sent until that first reply lands - which serialises a broadcast (measured)
  sent:.[{-25!(x;y); flushhandles x; 1b};(handles;tosend);{(0b;"error: ",x)}];
  if[not first sent;:sent];
  / block and wait for the results
  res:{$[y;@[x;(::);(0b;"error: comm fail: handle closed while waiting for result")];(0b;"error: comm fail: failed to send query")]}'[abs handles;sent];
  / return results
  (res[;0];res[;1])}

postback:{[handles;query;postback]
  / for sending asynchronous postback message to a list of handles via async broadcast where the message is wrapped in the function postback
  q:({[q;p] (p;@[value;q;{"error: server fail: ",x}])};query;postback);
  tosend:({[q] @[neg .z.w;@[{[q] value q};q;{"error: server fail: ",x}];()]};q);
  / error trapping sending the query down the handle followed by an async flush.
  / the flush is what makes the returned success vector mean "on the wire" rather than "queued" -
  / nothing here waits for a reply, so an unflushed postback is indistinguishable from a lost one
  .[{-25!(x;y); flushhandles x; (count x)#1b};(handles;tosend);{(y#0b;"error: ",x)}[;count handles]]}