/ stub upstream for di.torq.proc.chainedtp's unit tests - not a test file itself; test.q launches it as a separate q
/ process and dials it, so di.subscriptions' .u.subdetails call and the module's .z.pc handling run over a genuine
/ IPC handle without a full tickerplant. The reply is whatever SD the harness last set over the handle, narrowed to
/ the requested tables; every call is counted so the harness can assert a single subscription per init.

SD:()!();
CALLS:0;

.u.subdetails:{[tabs;syms]
  CALLS+:1;
  r:SD;
  / a segmented reply carries schemalist, not tables/schemas - narrowing those would invent keys
  if[(not tabs~`) and `schemas in key r;
    r[`tables]:(),tabs;
    r[`schemas]:((),tabs)#r`schemas];
  r
  };

/ the same reply under the BARE root name a segmented tickerplant publishes. di.subscriptions decides
/ which name to call from the root `tptype` it probes for, so the harness flips this stub between the
/ two protocols by setting tptype over the handle - no second stub process needed. tptype is left
/ UNDEFINED here, so the probe defaults to `standard and every existing test is unaffected.
subdetails:.u.subdetails;
