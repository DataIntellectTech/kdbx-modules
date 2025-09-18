send:{[w;h;q] 
 // build the query to send
 tosend:$[w; ({[q] @[neg .z.w;@[{[q] (1b;value q)};q;{(0b;"error: server fail:",x)}];()]};q);
             ({[q] @[neg .z.w;@[{[q] value q};q;{"error: server fail:",x}];()]};q)];
 .[{x@y; x(::);1b};(h;tosend);0b]}

// use this to make deferred sync calls
// it will send the query down each of the handles, then block and wait on the handles
// result set is (successvector (1 for each handle); result vector)
deferred:{[handles;query]
 // send the query down each handle
 sent:send[1b;;query] each handles:neg abs handles,();

 // block and wait for the results
 res:{$[y;@[x;(::);(0b;"error: comm fail: handle closed while waiting for result")];(0b;"error: comm fail: failed to send query")]}'[abs handles;sent];

 // return results
 (res[;0];res[;1])}

// Wrap the supplied query in a postback function
// Don't block the handle when waiting
// Success vector is returned 
postback:{[handles;query;postback] send[0b;;({[q;p] (p;@[value;q;{"error: server fail:",x}])};query;postback)] each handles:neg abs handles,()}
