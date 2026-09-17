/ stub upstream for di.torq.proc.chainedtp's unit tests - not a test file itself; test.q launches it as a separate q
/ process and dials it, so di.subscriptions' .u.subdetails call and the module's .z.pc handling run over a genuine
/ IPC handle without a full tickerplant. The reply is whatever SD the harness last set over the handle, narrowed to
/ the requested tables; every call is counted so the harness can assert a single subscription per init.

SD:()!();
CALLS:0;

.u.subdetails:{[tabs;syms]
  CALLS+:1;
  r:SD;
  if[not tabs~`;
    r[`tables]:(),tabs;
    r[`schemas]:((),tabs)#r`schemas];
  r
  };
