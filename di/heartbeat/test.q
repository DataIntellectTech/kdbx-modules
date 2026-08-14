/ integration fixtures for di.heartbeat - spawn a real publisher process and subscribe to it
/ this is the only way to exercise the two failures a pubsub mock cannot catch:
/   1. the remote-subscribe handshake, which depends on .z.w resolving to the MONITOR's connection
/      inside an inbound call on the PUBLISHER
/   2. the root schema table, without which di.pubsub silently refuses the subscription and
/      discards every published row

/ pick a free port by binding one and immediately releasing it. the while-iterator {cond}{body}/ is
/ used rather than a while loop: the style guide bans do/while outright, and a bounded retry is still
/ an iterator - 0 is the "not found yet" state, and a failed bind leaves it at 0 for another go
freeport:{[]
  p:{0=x}{@[{[c] system"p ",string c;c};10000+rand 40000;0]}/0;
  system"p 0";
  :p;
  };

/ write the publisher script the child process will run
writechild:{[path;port]
  src:(
    "hb:use`di.heartbeat;";
    "ps:use`di.pubsub;";
    "/ stub timer - this test drives publishheartbeat by hand, so nothing needs scheduling";
    "tmr:`addjob`deletejobs!((enlist`custom)!enlist {[i;f;p;pe;m;o]};{[ids]});";
    "lg:`info`warn`error!({[c;m]};{[c;m]};{[c;m]});";
    "/ heartbeat init FIRST - it publishes the root schema table that di.pubsub then discovers.";
    "/ reversing these two lines is the silent failure this whole test exists to catch.";
    "hb.init[(`log`timer`pubsub!(lg;tmr;`publish`subscribe!(ps.publish;ps.subscribe))),";
    "  `proctype`procname!(`childtype;`childproc)];";
    "ps.init[];";
    "ready:1b;");
  path 0: src;
  };

/ poll for the child's port for up to 10s, then give up. state is (attempts;handle), threaded through
/ the while-iterator so the retry cap is part of the condition rather than a counter in a loop body.
/ the null handle is seeded 0Ni, not 0N - hopen returns an int, and a long seed would make the state
/ change type on the first iteration
awaithandle:{[port]
  s:{(null x 1) and x[0]<100}{[port;x]
    system"sleep 0.1";
    (x[0]+1;@[{hopen `$":localhost:",string x};port;0Ni])}[port]/(0;0Ni);
  :s 1;
  };

/ poll until the child's own init has completed. the probe is protected on the CHILD side, so a call
/ that lands before ready exists comes back 0b rather than throwing back across the connection
awaitready:{[h]
  {(not x 1) and x[0]<100}{[h;x]
    system"sleep 0.1";
    (x[0]+1;@[h;"@[{ready};::;0b]";0b])}[h]/(0;0b);
  };

/ launch the child and wait for it to answer
spawnpublisher:{[]
  port:freeport[];
  path:"/tmp/dihbchild",string[port],".q";
  writechild[hsym `$path;port];
  system"q ",path," -p ",string[port]," -q </dev/null >/tmp/dihbchild",string[port],".log 2>&1 &";
  h:awaithandle port;
  if[null h;'"di.heartbeat test: publisher process failed to start - see /tmp/dihbchild",string[port],".log"];
  / wait for its init to complete
  awaitready h;
  .ht.port:port;
  .ht.h:h;
  :h;
  };

/ write the phone book the REAL di.servers reads, naming the spawned publisher as the one peer to
/ connect to. di.servers' header check is strict and positional (host,port,proctype,procname, v1
/ 4-column), so the header line must be exactly this or readprocesscsv fails loud. proctype and
/ procname must match the identity writechild gives the child, or di.servers dials a row that is not
/ the process we spawned. no self row: di.servers' own suite covers self-exclusion, and leaving it out
/ keeps this fixture to the one thing it exists to prove
writeserverscsv:{[port]
  path:"/tmp/dihbservers",string[port],".csv";
  (hsym `$path) 0: (
    "host,port,proctype,procname";
    "localhost,",string[port],",childtype,childproc");
  :path;
  };

/ the monitor's own upd - di.heartbeat deliberately does NOT install this itself.
/ hbm is indexed, not dotted: module dot-sugar only works on a plain top-level name, and fails
/ silently inside a lambda or on a dotted one
installupd:{[]
  upd::{[t;x] if[t=`heartbeat;hbm[`storeheartbeat]x]};
  };

/ force the parent to drain any async messages the publisher has pushed
drain:{[h]
  h"1";
  };

/ make the publisher unresponsive for a while WITHOUT killing it - the "alive but stalled" state a
/ heartbeat exists to detect. sent async so this call itself does not block
hangpeer:{[h;secs]
  (neg h)"system\"sleep ",string[secs],"\"";
  };

/ elapsed time for a unary call. used to prove the subscribe does not block against a hung peer:
/ the synchronous version waited out the ENTIRE hang, and because it runs inside a di.timer job on a
/ single thread it stalled publishheartbeat and checkheartbeat with it, so the monitor fell silent to
/ its own monitors at exactly the moment a peer was misbehaving
elapsed:{[f;arg]
  t0:.z.p;
  f arg;
  :.z.p-t0;
  };

cleanup:{[]
  / terminate the child FIRST - hclose only drops our end of the socket and would leave the process
  / running for the lifetime of the test host. sent SYNC inside a protected apply: the call cannot
  / return because the peer exits mid-request, and swallowing that error is the point. an async send
  / is not reliable here - it can sit in the output buffer and be discarded by the hclose below
  @[{x"exit 0"};.ht.h;::];
  @[hclose;.ht.h;::];
  / the servers phone book is only written by the di.servers block, so rm -f covers the runs that
  / never created one
  @[{system"rm -f /tmp/dihbchild",string[x],".q /tmp/dihbchild",string[x],".log /tmp/dihbservers",
    string[x],".csv"};.ht.port;::];
  };
