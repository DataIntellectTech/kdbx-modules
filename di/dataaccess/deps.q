/ hard module dependencies and their minimum versions, validated by di.depcheck.
/ the modularisation plan places di.dataaccess in the PROCESS tier with
/ `-> di.asyncdispatch, di.serverselect`. both edges are real `use` imports at the top of
/ dataaccess.q, and each is listed here with what this module actually calls through it, so a
/ reviewer can check the edge against the code rather than trust it:
/   di.asyncdispatch - execqueryto. one call per shard, dispatched with replyto:0Ni so the postback
/                      is invoked locally by value rather than sent to a handle. NOT execquery:
/                      that captures clienth:.z.w at call time, which in-process is the end client's
/                      handle, so shard replies bypassed this module entirely and the join never ran
/   di.serverselect  - getservers[`servertype;`;()!()]. getrouting reads the `servertype` column to
/                      learn which servertypes are currently reachable, and drops partitions whose
/                      servertype is not among them. server SELECTION (which concrete handle serves
/                      a shard) stays di.asyncdispatch's job; this module only asks which types exist
/ log, timer and resultcallback stay INJECTED via init - the plan's tier table excludes logging and
/ timer management from the hard dependency tree by design, and resultcallback is a plain symbol.
/ di.handlers is NOT a dependency: this module assigns no .z.* handler. removeclient is exported for
/ a caller to register on .z.pc, exactly as di.asyncdispatch exports removeclienthandle rather than
/ self-registering it; wiring that up is di.torq's job. see dataaccess.md
deps:`di.asyncdispatch`di.serverselect!("0.1.0";"0.1.0");
