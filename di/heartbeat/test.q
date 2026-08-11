/ integration fixtures for di.heartbeat - spawn a real publisher process and subscribe to it
/ this is the only way to exercise the two failures a pubsub mock cannot catch:
/   1. the remote-subscribe handshake, which depends on .z.w resolving to the MONITOR's connection
/      inside an inbound call on the PUBLISHER
/   2. the root schema table, without which di.pubsub silently refuses the subscription and
/      discards every published row

/ pick a free port by binding one and immediately releasing it
freeport:{[]
  p:0;
  while[not p;
    c:10000+rand 40000;
    if[not null @[{system"p ",string x;x};c;0N];p:c]];
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

/ launch the child and wait for it to answer
spawnpublisher:{[]
  port:freeport[];
  path:"/tmp/dihbchild",string[port],".q";
  writechild[hsym `$path;port];
  system"q ",path," -p ",string[port]," -q </dev/null >/tmp/dihbchild",string[port],".log 2>&1 &";
  h:0N;
  i:0;
  while[(null h) and i<100;
    h:@[{hopen `$":localhost:",string x};port;0N];
    i+:1;
    system"sleep 0.1"];
  if[null h;'"di.heartbeat test: publisher process failed to start - see /tmp/dihbchild",string[port],".log"];
  / wait for its init to complete
  i:0;
  while[(not @[h;"@[{ready};::;0b]";0b]) and i<100;
    i+:1;
    system"sleep 0.1"];
  .ht.port:port;
  .ht.h:h;
  :h;
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
  @[{system"rm -f /tmp/dihbchild",string[x],".q /tmp/dihbchild",string[x],".log"};.ht.port;::];
  };
